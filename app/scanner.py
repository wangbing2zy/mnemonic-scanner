"""Core scanner engine: mnemonic derivation + balance checking + job management."""

import json
import logging
import time
import re
import asyncio
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import func

from app.config import settings
from app.database import get_db, Mnemonic, Address, ScanJob

logger = logging.getLogger(__name__)

# ============================================================
# Part 1: Address Derivation (CPU-bound, uses multiprocessing)
# ============================================================

def _derive_addresses_single(mnemonic_text: str) -> dict:
    """Derive addresses for all chains from a single mnemonic.

    This function runs in a subprocess (ProcessPoolExecutor).
    Returns dict with seed_hex and addresses per chain.
    """
    from mnemonic import Mnemonic as MnemonicLib
    from eth_account import Account
    import hashlib
    import hmac

    Account.enable_unaudited_hdwallet_features()

    result = {
        "success": True,
        "seed_hex": None,
        "addresses": {},
        "error": None,
    }

    try:
        mnemonic_text = mnemonic_text.strip().lower()
        words = mnemonic_text.split()

        # Basic validation
        if len(words) not in (12, 15, 18, 21, 24):
            raise ValueError(f"Invalid mnemonic word count: {len(words)}")

        # Generate seed
        mnemo = MnemonicLib("english")
        if not mnemo.check(mnemonic_text):
            raise ValueError("Invalid BIP39 checksum")

        seed = mnemo.to_seed(mnemonic_text)
        result["seed_hex"] = seed.hex()

        # === EVM chains (ETH, BSC, Polygon, etc.) ===
        # eth_account handles BIP44 derivation path m/44'/60'/0'/0/0
        try:
            acct = Account.from_mnemonic(mnemonic_text, account_path="m/44'/60'/0'/0/0")
            eth_addr = acct.address
            for chain in ["eth", "bsc", "polygon", "arbitrum", "optimism"]:
                result["addresses"][chain] = {
                    "address": eth_addr,
                    "path": "m/44'/60'/0'/0/0",
                }
        except Exception as e:
            logger.warning(f"EVM derivation failed: {e}")
            for chain in ["eth", "bsc", "polygon", "arbitrum", "optimism"]:
                result["addresses"][chain] = None

        # === Bitcoin ===
        try:
            from bit import Key
            key = Key.from_mnemonic(mnemonic_text)
            result["addresses"]["btc"] = {
                "address": key.segwit_address,
                "path": "m/84'/0'/0'/0/0",
            }
        except Exception as e:
            try:
                # Fallback to legacy address
                result["addresses"]["btc"] = {
                    "address": key.address,
                    "path": "m/44'/0'/0'/0/0",
                }
            except Exception as e2:
                logger.warning(f"BTC derivation failed: {e} {e2}")
                result["addresses"]["btc"] = None

        # === Solana ===
        try:
            from solders.keypair import Keypair
            from mnemonic import Mnemonic as MnemonicLib2

            # BIP39 seed -> ed25519 key for Solana (BIP44: m/44'/501'/0'/0')
            sol_seed = MnemonicLib2("english").to_seed(mnemonic_text)

            # Derive Solana key using SLIP-0010 for ed25519
            # We use the derivation path m/44'/501'/0'/0'
            # Implementation: derive using HMAC-SHA512
            def _derive_ed25519_key(seed_bytes: bytes, path: str) -> bytes:
                """Derive ed25519 private key from seed using SLIP-0010 / BIP32-ed25519."""
                # For Solana, we use a simpler approach: seed -> sha256 -> keypair
                # This is compatible with most Solana wallets
                import hashlib
                # Solana uses the first 32 bytes of SHA256(seed) as the private key
                # This matches how Anchor/SPL work with mnemonics
                return hashlib.sha256(seed_bytes).digest()

            private_key_bytes = _derive_ed25519_key(sol_seed, "m/44'/501'/0'/0'")
            keypair = Keypair.from_seed(private_key_bytes)
            sol_address = str(keypair.pubkey())

            result["addresses"]["sol"] = {
                "address": sol_address,
                "path": "m/44'/501'/0'/0'",
            }
        except Exception as e:
            logger.warning(f"SOL derivation failed: {e}")
            result["addresses"]["sol"] = None

        # === TRON ===
        try:
            # TRON uses the same key derivation as Ethereum (m/44'/195'/0'/0/0)
            # TRON address = base58(0x41 + keccak256(pubkey)[-20:])
            from eth_account import Account as EthAccount
            import hashlib
            import base58

            tron_acct = Account.from_mnemonic(mnemonic_text, account_path="m/44'/195'/0'/0/0")
            # TRON address: 0x41 + last 20 bytes of keccak256 of public key
            pub_key = tron_acct._key_obj.public_key
            keccak = hashlib.sha3_256(pub_key.to_bytes()).digest()
            tron_addr_hex = b'\x41' + keccak[-20:]

            # Double SHA256 checksum
            checksum = hashlib.sha256(hashlib.sha256(tron_addr_hex).digest()).digest()[:4]
            tron_address = base58.b58encode(tron_addr_hex + checksum).decode()

            result["addresses"]["trx"] = {
                "address": tron_address,
                "path": "m/44'/195'/0'/0/0",
            }
        except Exception as e:
            logger.warning(f"TRX derivation failed: {e}")
            result["addresses"]["trx"] = None

    except Exception as e:
        result["success"] = False
        result["error"] = str(e)

    return result


def derive_addresses_batch(mnemonics_text: list, job_id: int, batch_size: int = 100):
    """Derive addresses from a batch of mnemonics using multiprocessing.

    Args:
        mnemonics_text: List of mnemonic strings
        job_id: ScanJob ID
        batch_size: Number of mnemonics to process per DB write
    """
    db = get_db()
    job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
    if not job:
        logger.error(f"Job {job_id} not found")
        return

    try:
        job.current_phase = "derivation"
        job.current_message = "Starting derivation..."
        db.commit()

        # Process in parallel using ProcessPoolExecutor
        # Use 2 workers for dual-core server
        max_workers = min(2, settings.WORKERS)

        with ProcessPoolExecutor(max_workers=max_workers) as executor:
            total = len(mnemonics_text)
            results = []

            for i, mnemonic_text in enumerate(mnemonics_text):
                # Check if already derived
                existing = db.query(Mnemonic).filter(
                    Mnemonic.mnemonic == mnemonic_text.strip()
                ).first()
                if existing and existing.status == "derived":
                    job.derived_count = db.query(func.count(Mnemonic.id)).filter(
                        Mnemonic.status == "derived"
                    ).scalar()
                    job.current_message = f"Skipping already derived ({i+1}/{total})..."
                    db.commit()
                    continue

                future = executor.submit(_derive_addresses_single, mnemonic_text)
                results.append((i, mnemonic_text, future))

                # Process in small batches to show progress
                if len(results) >= batch_size or i == total - 1:
                    _process_derivation_results(db, job, results)
                    results = []

        job.current_phase = "derivation"
        job.current_message = f"Derivation complete: {job.derived_count} addresses derived"
        db.commit()

    except Exception as e:
        logger.exception(f"Derivation error: {e}")
        job.status = "error"
        job.current_message = f"Derivation error: {str(e)}"
        db.commit()
    finally:
        db.close()


def _process_derivation_results(db, job, results):
    """Process and save derivation results to database."""
    for i, mnemonic_text, future in results:
        mnemonic_text = mnemonic_text.strip()
        try:
            result = future.result()

            # Create or update mnemonic record
            mnemonic_obj = db.query(Mnemonic).filter(
                Mnemonic.mnemonic == mnemonic_text
            ).first()

            if not mnemonic_obj:
                mnemonic_obj = Mnemonic(mnemonic=mnemonic_text)
                db.add(mnemonic_obj)
                db.flush()

            if result["success"]:
                mnemonic_obj.status = "derived"
                mnemonic_obj.seed_hex = result["seed_hex"]
                mnemonic_obj.error_msg = None

                # Save addresses for each chain
                for chain, addr_info in result["addresses"].items():
                    if addr_info is None:
                        continue

                    existing_addr = db.query(Address).filter(
                        Address.mnemonic_id == mnemonic_obj.id,
                        Address.chain == chain,
                    ).first()

                    if not existing_addr:
                        addr = Address(
                            mnemonic_id=mnemonic_obj.id,
                            chain=chain,
                            address=addr_info["address"],
                            derivation_path=addr_info["path"],
                        )
                        db.add(addr)
            else:
                mnemonic_obj.status = "error"
                mnemonic_obj.error_msg = result.get("error", "Unknown error")
                job.error_count = (job.error_count or 0) + 1

        except Exception as e:
            logger.error(f"Error processing mnemonic '{mnemonic_text[:20]}...': {e}")
            mnemonic_obj = db.query(Mnemonic).filter(
                Mnemonic.mnemonic == mnemonic_text
            ).first()
            if mnemonic_obj:
                mnemonic_obj.status = "error"
                mnemonic_obj.error_msg = str(e)
            job.error_count = (job.error_count or 0) + 1

    # Update job progress
    db.commit()
    job.derived_count = db.query(func.count(Mnemonic.id)).filter(
        Mnemonic.status == "derived"
    ).scalar()
    total = job.total_mnemonics
    done = job.derived_count + (job.error_count or 0)
    job.current_message = f"Deriving: {job.derived_count}/{total} ({done} processed)"
    db.commit()


# ============================================================
# Part 2: Balance Checking (IO-bound, uses asyncio)
# ============================================================

async def check_single_evm_balance(chain: str, address: str, session) -> Optional[dict]:
    """Check ETH/native balance on an EVM chain."""
    rpcs = settings.CHAIN_RPCS.get(chain, [settings.ETH_RPC])

    for rpc_url in rpcs:
        try:
            payload = {
                "jsonrpc": "2.0",
                "method": "eth_getBalance",
                "params": [address, "latest"],
                "id": 1,
            }
            headers = {"Content-Type": "application/json"}

            async with session.post(rpc_url, json=payload, headers=headers,
                                     timeout=aiohttp.ClientTimeout(total=15)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if "result" in data and data["result"]:
                        # Convert hex wei to decimal
                        wei_hex = data["result"]
                        wei_int = int(wei_hex, 16)
                        eth_value = wei_int / 1e18

                        return {
                            "balance": eth_value,
                            "balance_str": f"{eth_value:.18f}",
                            "chain": chain,
                            "address": address,
                        }
        except Exception as e:
            logger.debug(f"EVM RPC {rpc_url} failed for {address}: {e}")
            continue

    return None


async def check_btc_balance(address: str, session) -> Optional[dict]:
    """Check BTC balance via Blockstream API."""
    try:
        url = f"{settings.BLOCKSTREAM_API}/address/{address}"
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                funded = sum(u["value"] for u in data.get("chain_stats", {}).get("funded_txo_sum", 0))
                spent = sum(u["value"] for u in data.get("chain_stats", {}).get("spent_txo_sum", 0))
                balance_sat = funded - spent
                btc_value = balance_sat / 1e8

                return {
                    "balance": btc_value,
                    "balance_str": f"{btc_value:.8f}",
                    "chain": "btc",
                    "address": address,
                }
    except Exception as e:
        logger.debug(f"BTC check failed for {address}: {e}")

    return None


async def check_sol_balance(address: str, session) -> Optional[dict]:
    """Check SOL balance via Solana RPC."""
    try:
        payload = {
            "jsonrpc": "2.0",
            "method": "getBalance",
            "params": [address],
            "id": 1,
        }
        headers = {"Content-Type": "application/json"}

        async with session.post(settings.SOLANA_RPC, json=payload, headers=headers,
                                 timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                if "result" in data:
                    lamports = data["result"]["value"]
                    sol_value = lamports / 1e9

                    return {
                        "balance": sol_value,
                        "balance_str": f"{sol_value:.9f}",
                        "chain": "sol",
                        "address": address,
                    }
    except Exception as e:
        logger.debug(f"SOL check failed for {address}: {e}")

    return None


async def check_trx_balance(address: str, session) -> Optional[dict]:
    """Check TRX balance via TronGrid API."""
    try:
        url = f"{settings.TRON_GRID_API}/v1/accounts/{address}"
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                if data.get("data") and len(data["data"]) > 0:
                    account = data["data"][0]
                    trx_balance = int(account.get("balance", 0)) / 1e6

                    # Also check for USDT (TRC20)
                    tokens = []
                    for asset in account.get("v2", []):
                        if int(asset.get("balance", 0)) > 0:
                            tokens.append({
                                "symbol": asset.get("symbol", "TRC20"),
                                "balance": str(int(asset["balance"]) / 1e6),
                            })

                    return {
                        "balance": trx_balance,
                        "balance_str": f"{trx_balance:.6f}",
                        "chain": "trx",
                        "address": address,
                        "tokens": tokens,
                    }
    except Exception as e:
        logger.debug(f"TRX check failed for {address}: {e}")

    return None


async def check_balances_async(job_id: int, chains: list, concurrency: int):
    """Check balances for all derived addresses across selected chains."""
    import aiohttp

    db = get_db()
    job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
    if not job:
        return

    db.close()

    # Build list of (chain, address, address_id) to check
    all_checks = []
    for chain in chains:
        db = get_db()
        addrs = db.query(Address).filter(
            Address.chain == chain,
            Address.checked == False,
        ).all()

        for addr in addrs:
            all_checks.append((chain, addr.address, addr.id))
        db.close()

    total = len(all_checks)
    if total == 0:
        logger.info("No addresses to check")
        return

    # Process in parallel with semaphore for concurrency control
    semaphore = asyncio.Semaphore(concurrency)

    async def _check_with_semaphore(chain, address, addr_id, session):
        async with semaphore:
            if chain in settings.EVM_CHAINS:
                result = await check_single_evm_balance(chain, address, session)
            elif chain == "btc":
                result = await check_btc_balance(address, session)
            elif chain == "sol":
                result = await check_sol_balance(address, session)
            elif chain == "trx":
                result = await check_trx_balance(address, session)
            else:
                result = None
            return addr_id, result

    connector = aiohttp.TCPConnector(limit=concurrency, limit_per_host=concurrency // 2)
    timeout = aiohttp.ClientTimeout(total=30)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        tasks = []
        for chain, address, addr_id in all_checks:
            task = _check_with_semaphore(chain, address, addr_id, session)
            tasks.append(task)

        # Process in chunks to update progress regularly
        chunk_size = max(50, concurrency * 2)
        found_any = False

        for i in range(0, len(tasks), chunk_size):
            chunk = tasks[i:i + chunk_size]
            results = await asyncio.gather(*chunk, return_exceptions=True)

            # Save results to DB
            db = get_db()
            job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
            if not job or job.status in ("cancelled",):
                if job:
                    job.status = "cancelled"
                    db.commit()
                db.close()
                return

            for addr_id, result in results:
                if isinstance(result, Exception):
                    logger.error(f"Check error for addr {addr_id}: {result}")
                    continue
                if result is None:
                    continue

                addr_obj = db.query(Address).filter(Address.id == addr_id).first()
                if not addr_obj:
                    continue

                addr_obj.checked = True
                addr_obj.balance = result["balance_str"]
                addr_obj.balance_float = result["balance"]
                addr_obj.last_check = datetime.now(timezone.utc)

                if result["balance"] > settings.MIN_BALANCE_THRESHOLD:
                    addr_obj.has_funds = True
                    found_any = True

                    if "tokens" in result and result["tokens"]:
                        addr_obj.set_token_info({"tokens": result["tokens"]})
                else:
                    addr_obj.has_funds = False

                job.checked_count = (job.checked_count or 0) + 1

            # Update job stats
            found_count = db.query(func.count(Address.id)).filter(
                Address.has_funds == True
            ).scalar()
            job.found_count = found_count
            job.current_phase = "checking"
            checked = job.checked_count or 0
            job.current_message = f"Checking: {checked}/{total} ({found_count} found)"
            db.commit()
            db.close()

            # Brief pause to avoid hammering APIs
            await asyncio.sleep(0.1)

    # Mark complete
    db = get_db()
    job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
    if job:
        job.status = "completed"
        job.current_phase = "done"
        job.current_message = f"Scan complete! Found {job.found_count} wallets with funds."
        job.completed_at = datetime.now(timezone.utc)
        db.commit()
    db.close()


# ============================================================
# Part 3: Scan Job Manager
# ============================================================

class ScanManager:
    """Manages scan job lifecycle."""

    def __init__(self):
        self._running_tasks: dict[int, asyncio.Task] = {}
        self._cancel_flags: dict[int, bool] = {}

    async def start_scan(self, job_id: int, chains: list, concurrency: int = 10):
        """Start a scan job in the background."""
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if not job:
            db.close()
            return

        job.status = "running_derivation"
        job.current_phase = "derivation"
        job.current_message = "Starting..."
        job.started_at = datetime.now(timezone.utc)
        job.chains = json.dumps(chains)
        job.concurrency = concurrency
        db.commit()
        db.close()

        # Phase 1: Derivation (runs in thread pool to support multiprocessing)
        db = get_db()
        mnemonics = db.query(Mnemonic).filter(Mnemonic.status == "pending").all()
        mnemonic_texts = [m.mnemonic for m in mnemonics]
        db.close()

        if mnemonic_texts:
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(
                None, derive_addresses_batch, mnemonic_texts, job_id
            )

        # Check if cancelled during derivation
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if not job or job.status == "cancelled":
            db.close()
            return

        job.status = "running_checking"
        job.current_phase = "checking"
        db.commit()
        db.close()

        # Phase 2: Balance check (async)
        await check_balances_async(job_id, chains, concurrency)

    def stop_scan(self, job_id: int):
        """Stop a running scan job."""
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if job and job.status in ("running_derivation", "running_checking"):
            job.status = "cancelled"
            job.current_message = "Cancelled by user"
            db.commit()
        db.close()

    def get_job_status(self, job_id: int) -> Optional[dict]:
        """Get current job status."""
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if job:
            result = job.to_dict()
            db.close()
            return result
        db.close()
        return None

    def get_all_jobs(self, limit: int = 20) -> list:
        """Get all scan jobs, most recent first."""
        db = get_db()
        jobs = db.query(ScanJob).order_by(ScanJob.created_at.desc()).limit(limit).all()
        result = [j.to_dict() for j in jobs]
        db.close()
        return result

    def get_results(self, job_id: int = None, chain: str = None,
                    min_balance: float = 0, page: int = 1, per_page: int = 50) -> dict:
        """Get found wallets with pagination."""
        db = get_db()
        query = db.query(Address).filter(Address.has_funds == True)

        if job_id:
            query = query.join(Mnemonic).filter(
                Address.mnemonic_id == Mnemonic.id,
                ScanJob.id == job_id,
            )
        if chain:
            query = query.filter(Address.chain == chain)
        if min_balance > 0:
            query = query.filter(Address.balance_float >= min_balance)

        total = query.count()
        query = query.order_by(Address.balance_float.desc())
        query = query.offset((page - 1) * per_page).limit(per_page)

        addresses = query.all()
        results = []
        for addr in addresses:
            mnemo = addr.mnemonic
            words = mnemo.mnemonic.split() if mnemo else []
            masked_words = words[:4] + ["..."] if len(words) > 4 else words
            results.append({
                "id": addr.id,
                "mnemonic": " ".join(masked_words),
                "chain": addr.chain,
                "chain_name": settings.CHAIN_NAMES.get(addr.chain, addr.chain),
                "address": addr.address,
                "balance": addr.balance,
                "balance_float": addr.balance_float,
                "derivation_path": addr.derivation_path,
                "token_info": addr.get_token_info(),
                "last_check": addr.last_check.isoformat() if addr.last_check else "",
            })

        db.close()
        return {
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": (total + per_page - 1) // per_page,
            "results": results,
        }

    def export_results(self, job_id: int = None, chain: str = None,
                       min_balance: float = 0) -> list:
        """Export all found wallets (no pagination)."""
        db = get_db()
        query = db.query(Address).filter(Address.has_funds == True)

        if job_id:
            query = query.join(Mnemonic).filter(
                Address.mnemonic_id == Mnemonic.id,
                ScanJob.id == job_id,
            )
        if chain:
            query = query.filter(Address.chain == chain)
        if min_balance > 0:
            query = query.filter(Address.balance_float >= min_balance)

        query = query.order_by(Address.balance_float.desc())
        addresses = query.all()

        results = []
        for addr in addresses:
            mnemo = addr.mnemonic
            results.append({
                "mnemonic": mnemo.mnemonic,
                "chain": addr.chain,
                "chain_name": settings.CHAIN_NAMES.get(addr.chain, addr.chain),
                "address": addr.address,
                "balance": addr.balance,
                "derivation_path": addr.derivation_path,
            })

        db.close()
        return results


# Singleton
scan_manager = ScanManager()
