#!/bin/bash
#
# 助记词批量扫描工具 - 服务器一键部署脚本
# 在服务器上直接执行: bash -c "$(curl -s http://...)"
# 或直接复制粘贴到终端
#
set -e

APP_PORT=8000
APP_DIR="$HOME/mnemonic-scanner"

echo "========================================"
echo "  助记词批量扫描工具 - 部署"
echo "  目标端口: $APP_PORT"
echo "  安装目录: $APP_DIR"
echo "========================================"

# 1. 安装系统依赖
echo "[1/5] 安装系统依赖..."
sudo apt-get update -qq
sudo apt-get install -y -qq python3 python3-pip python3-venv curl

# 2. 创建项目目录
echo "[2/5] 创建项目..."
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# 3. 创建所有项目文件
echo "[3/5] 写入项目文件..."

# --- requirements.txt ---
cat > requirements.txt << 'REQEOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
aiofiles==24.1.0
sqlalchemy==2.0.35
aiosqlite==0.20.0
python-dotenv==1.0.1
mnemonic==0.21
web3==7.3.0
aiohttp==3.10.5
httpx==0.27.2
base58==2.1.1
solders==0.21.0
REQEOF

# --- .env ---
cat > .env << 'ENVEOF'
HOST=0.0.0.0
PORT=8000
WORKERS=2
DATABASE_URL=sqlite+aiosqlite:///./data/scanner.db
UPLOAD_DIR=./uploads
MAX_UPLOAD_SIZE_MB=500
DEFAULT_CONCURRENCY=10
MIN_BALANCE_THRESHOLD=0
ETH_RPC=https://eth.llamarpc.com
ETH_RPC_FALLBACK1=https://rpc.ankr.com/eth
ETH_RPC_FALLBACK2=https://cloudflare-eth.com
BSC_RPC=https://bsc-dataseed.binance.org
POLYGON_RPC=https://polygon-rpc.com
ARBITRUM_RPC=https://arb1.arbitrum.io/rpc
OPTIMISM_RPC=https://mainnet.optimism.io
BLOCKSTREAM_API=https://blockstream.info/api
SOLANA_RPC=https://api.mainnet-beta.solana.com
TRON_GRID_API=https://api.trongrid.io
ENVEOF

# --- 创建目录 ---
mkdir -p app/templates app/static data uploads

# --- app/__init__.py ---
touch app/__init__.py

# --- app/config.py ---
cat > app/config.py << 'PYEOF'
"""Application configuration loaded from .env file."""

import os
from dotenv import load_dotenv

load_dotenv()


class Settings:
    HOST: str = os.getenv("HOST", "0.0.0.0")
    PORT: int = int(os.getenv("PORT", "8000"))
    WORKERS: int = int(os.getenv("WORKERS", "2"))

    DATABASE_URL: str = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./data/scanner.db")

    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", "./uploads")
    MAX_UPLOAD_SIZE_MB: int = int(os.getenv("MAX_UPLOAD_SIZE_MB", "500"))

    DEFAULT_CONCURRENCY: int = int(os.getenv("DEFAULT_CONCURRENCY", "10"))
    MIN_BALANCE_THRESHOLD: float = float(os.getenv("MIN_BALANCE_THRESHOLD", "0"))

    # EVM RPCs
    ETH_RPC: str = os.getenv("ETH_RPC", "https://eth.llamarpc.com")
    ETH_RPC_FALLBACK1: str = os.getenv("ETH_RPC_FALLBACK1", "https://rpc.ankr.com/eth")
    ETH_RPC_FALLBACK2: str = os.getenv("ETH_RPC_FALLBACK2", "https://cloudflare-eth.com")

    BSC_RPC: str = os.getenv("BSC_RPC", "https://bsc-dataseed.binance.org")
    BSC_RPC_FALLBACK1: str = os.getenv("BSC_RPC_FALLBACK1", "https://bsc-dataseed1.binance.org")
    BSC_RPC_FALLBACK2: str = os.getenv("BSC_RPC_FALLBACK2", "https://bsc-dataseed2.binance.org")

    POLYGON_RPC: str = os.getenv("POLYGON_RPC", "https://polygon-rpc.com")
    ARBITRUM_RPC: str = os.getenv("ARBITRUM_RPC", "https://arb1.arbitrum.io/rpc")
    OPTIMISM_RPC: str = os.getenv("OPTIMISM_RPC", "https://mainnet.optimism.io")

    BLOCKSTREAM_API: str = os.getenv("BLOCKSTREAM_API", "https://blockstream.info/api")
    SOLANA_RPC: str = os.getenv("SOLANA_RPC", "https://api.mainnet-beta.solana.com")
    TRON_GRID_API: str = os.getenv("TRON_GRID_API", "https://api.trongrid.io")

    # Chain display names
    CHAIN_NAMES: dict = {
        "eth": "Ethereum",
        "bsc": "BSC",
        "polygon": "Polygon",
        "arbitrum": "Arbitrum",
        "optimism": "Optimism",
        "btc": "Bitcoin",
        "sol": "Solana",
        "trx": "TRON",
    }

    # Chain default RPCs
    CHAIN_RPCS: dict = {
        "eth": [ETH_RPC, ETH_RPC_FALLBACK1, ETH_RPC_FALLBACK2],
        "bsc": [BSC_RPC, BSC_RPC_FALLBACK1, BSC_RPC_FALLBACK2],
        "polygon": [POLYGON_RPC],
        "arbitrum": [ARBITRUM_RPC],
        "optimism": [OPTIMISM_RPC],
    }

    CHAIN_BIP44: dict = {
        "eth": 60, "bsc": 60, "polygon": 60,
        "arbitrum": 60, "optimism": 60,
        "btc": 0, "sol": 501, "trx": 195,
    }

    EVM_CHAINS: set = {"eth", "bsc", "polygon", "arbitrum", "optimism"}


settings = Settings()
PYEOF

# --- app/database.py ---
cat > app/database.py << 'PYEOF'
"""Database models using SQLAlchemy 2.0 + SQLite."""

import json
from datetime import datetime, timezone
from sqlalchemy import (
    Column, Integer, String, Text, Float,
    Boolean, DateTime, ForeignKey, Index, text
)
from sqlalchemy.orm import DeclarativeBase, relationship, sessionmaker
from sqlalchemy.pool import NullPool

from app.config import settings


class Base(DeclarativeBase):
    pass


class Mnemonic(Base):
    __tablename__ = "mnemonics"

    id = Column(Integer, primary_key=True, autoincrement=True)
    mnemonic = Column(Text, unique=True, nullable=False, index=True)
    seed_hex = Column(Text, nullable=True)
    status = Column(String(20), default="pending", index=True)
    error_msg = Column(Text, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    addresses = relationship("Address", back_populates="mnemonic", cascade="all, delete-orphan")


class Address(Base):
    __tablename__ = "addresses"

    id = Column(Integer, primary_key=True, autoincrement=True)
    mnemonic_id = Column(Integer, ForeignKey("mnemonics.id", ondelete="CASCADE"), nullable=False, index=True)
    chain = Column(String(10), nullable=False, index=True)
    address = Column(String(100), nullable=False)
    derivation_path = Column(String(50), nullable=True)
    balance = Column(String(50), default="0")
    balance_float = Column(Float, default=0.0)
    checked = Column(Boolean, default=False, index=True)
    has_funds = Column(Boolean, default=False, index=True)
    token_info = Column(Text, nullable=True)
    last_check = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    mnemonic = relationship("Mnemonic", back_populates="addresses")

    __table_args__ = (
        Index("idx_mnemonic_chain", "mnemonic_id", "chain", unique=True),
    )

    def get_token_info(self):
        if self.token_info:
            return json.loads(self.token_info)
        return {}

    def set_token_info(self, info: dict):
        self.token_info = json.dumps(info, ensure_ascii=False)


class ScanJob(Base):
    __tablename__ = "scan_jobs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    status = Column(String(20), default="pending", index=True)
    chains = Column(Text, nullable=False, default="[]")
    concurrency = Column(Integer, default=10)
    min_balance = Column(String(20), default="0")

    total_mnemonics = Column(Integer, default=0)
    derived_count = Column(Integer, default=0)
    checked_count = Column(Integer, default=0)
    found_count = Column(Integer, default=0)
    error_count = Column(Integer, default=0)

    current_phase = Column(String(50), nullable=True)
    current_message = Column(Text, nullable=True)

    started_at = Column(DateTime, nullable=True)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc),
                        onupdate=lambda: datetime.now(timezone.utc))

    def get_chains(self):
        return json.loads(self.chains) if self.chains else []

    def set_chains(self, chain_list):
        self.chains = json.dumps(chain_list, ensure_ascii=False)

    def progress_pct(self):
        if self.status == "completed":
            return 100.0
        if self.total_mnemonics == 0:
            return 0.0
        if self.current_phase == "derivation":
            return round((self.derived_count / self.total_mnemonics) * 50, 1)
        elif self.current_phase in ("checking",):
            base = 50.0
            total_to_check = self.derived_count * len(self.get_chains())
            if total_to_check > 0:
                check_pct = (self.checked_count / total_to_check) * 50
                return round(base + check_pct, 1)
            return base
        return 0.0

    def to_dict(self):
        return {
            "id": self.id,
            "status": self.status,
            "chains": self.get_chains(),
            "concurrency": self.concurrency,
            "total": self.total_mnemonics,
            "derived": self.derived_count,
            "checked": self.checked_count,
            "found": self.found_count,
            "errors": self.error_count,
            "phase": self.current_phase or "",
            "message": self.current_message or "",
            "progress": self.progress_pct(),
            "created_at": self.created_at.isoformat() if self.created_at else "",
            "started_at": self.started_at.isoformat() if self.started_at else "",
            "completed_at": self.completed_at.isoformat() if self.completed_at else "",
        }


engine = None
SessionLocal = None


def init_db():
    global engine, SessionLocal
    sync_url = settings.DATABASE_URL.replace("+aiosqlite", "")
    engine = create_engine(
        sync_url,
        poolclass=NullPool,
        connect_args={"check_same_thread": False},
    )
    with engine.connect() as conn:
        conn.execute(text("PRAGMA journal_mode=WAL"))
        conn.execute(text("PRAGMA synchronous=NORMAL"))
        conn.execute(text("PRAGMA cache_size=-8000"))
        conn.commit()
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
    return engine, SessionLocal


def get_db():
    if SessionLocal is None:
        init_db()
    return SessionLocal()
PYEOF

# --- app/scanner.py ---
cat > app/scanner.py << 'PYEOF'
"""Core scanner engine: mnemonic derivation + balance checking + job management."""

import json
import logging
import asyncio
import aiohttp
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import func

from app.config import settings
from app.database import get_db, Mnemonic, Address, ScanJob

logger = logging.getLogger(__name__)


def _derive_addresses_single(mnemonic_text: str) -> dict:
    """Derive addresses for all chains from a single mnemonic. Runs in subprocess."""
    from mnemonic import Mnemonic as MnemonicLib
    from eth_account import Account
    import base58
    import hashlib

    Account.enable_unaudited_hdwallet_features()

    result = {"success": True, "seed_hex": None, "addresses": {}, "error": None}

    try:
        mnemonic_text = mnemonic_text.strip().lower()
        words = mnemonic_text.split()
        if len(words) not in (12, 15, 18, 21, 24):
            raise ValueError(f"Invalid mnemonic word count: {len(words)}")

        mnemo = MnemonicLib("english")
        if not mnemo.check(mnemonic_text):
            raise ValueError("Invalid BIP39 checksum")

        seed = mnemo.to_seed(mnemonic_text)
        result["seed_hex"] = seed.hex()

        # === EVM chains ===
        try:
            acct = Account.from_mnemonic(mnemonic_text, account_path="m/44'/60'/0'/0/0")
            eth_addr = acct.address
            for chain in ["eth", "bsc", "polygon", "arbitrum", "optimism"]:
                result["addresses"][chain] = {"address": eth_addr, "path": "m/44'/60'/0'/0/0"}
        except Exception as e:
            logger.warning(f"EVM derivation failed: {e}")

        # === Bitcoin ===
        try:
            from bit import Key
            key = Key.from_mnemonic(mnemonic_text)
            result["addresses"]["btc"] = {"address": key.segwit_address, "path": "m/84'/0'/0'/0/0"}
        except Exception as e:
            logger.warning(f"BTC derivation failed: {e}")
            result["addresses"]["btc"] = None

        # === Solana ===
        try:
            from solders.keypair import Keypair
            private_key_bytes = hashlib.sha256(seed).digest()
            keypair = Keypair.from_seed(private_key_bytes)
            result["addresses"]["sol"] = {"address": str(keypair.pubkey()), "path": "m/44'/501'/0'/0'"}
        except Exception as e:
            logger.warning(f"SOL derivation failed: {e}")
            result["addresses"]["sol"] = None

        # === TRON ===
        try:
            tron_acct = Account.from_mnemonic(mnemonic_text, account_path="m/44'/195'/0'/0/0")
            pub_key = tron_acct._key_obj.public_key
            keccak = hashlib.sha3_256(bytes(pub_key)).digest()
            tron_addr_hex = b'\x41' + keccak[-20:]
            checksum = hashlib.sha256(hashlib.sha256(tron_addr_hex).digest()).digest()[:4]
            tron_address = base58.b58encode(tron_addr_hex + checksum).decode()
            result["addresses"]["trx"] = {"address": tron_address, "path": "m/44'/195'/0'/0/0"}
        except Exception as e:
            logger.warning(f"TRX derivation failed: {e}")
            result["addresses"]["trx"] = None

    except Exception as e:
        result["success"] = False
        result["error"] = str(e)

    return result


def derive_addresses_batch(mnemonics_text: list, job_id: int, batch_size: int = 100):
    """Derive addresses from a batch of mnemonics using multiprocessing."""
    db = get_db()
    job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
    if not job:
        db.close()
        return

    try:
        job.current_phase = "derivation"
        job.current_message = "Starting derivation..."
        db.commit()

        with ProcessPoolExecutor(max_workers=2) as executor:
            total = len(mnemonics_text)
            results = []

            for i, mnemonic_text in enumerate(mnemonics_text):
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
    for i, mnemonic_text, future in results:
        mnemonic_text = mnemonic_text.strip()
        try:
            result = future.result()
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
                for chain, addr_info in result["addresses"].items():
                    if addr_info is None:
                        continue
                    existing = db.query(Address).filter(
                        Address.mnemonic_id == mnemonic_obj.id,
                        Address.chain == chain,
                    ).first()
                    if not existing:
                        addr = Address(
                            mnemonic_id=mnemonic_obj.id, chain=chain,
                            address=addr_info["address"],
                            derivation_path=addr_info["path"],
                        )
                        db.add(addr)
            else:
                mnemonic_obj.status = "error"
                mnemonic_obj.error_msg = result.get("error", "Unknown error")
                job.error_count = (job.error_count or 0) + 1
        except Exception as e:
            logger.error(f"Error processing mnemonic: {e}")
            job.error_count = (job.error_count or 0) + 1

    db.commit()
    job.derived_count = db.query(func.count(Mnemonic.id)).filter(
        Mnemonic.status == "derived"
    ).scalar()
    total = job.total_mnemonics
    done = job.derived_count + (job.error_count or 0)
    job.current_message = f"Deriving: {job.derived_count}/{total} ({done} processed)"
    db.commit()


async def check_single_evm_balance(chain: str, address: str, session) -> Optional[dict]:
    rpcs = settings.CHAIN_RPCS.get(chain, [settings.ETH_RPC])
    for rpc_url in rpcs:
        try:
            payload = {
                "jsonrpc": "2.0", "method": "eth_getBalance",
                "params": [address, "latest"], "id": 1,
            }
            async with session.post(rpc_url, json=payload,
                                     timeout=aiohttp.ClientTimeout(total=15)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data.get("result"):
                        wei_int = int(data["result"], 16)
                        eth_value = wei_int / 1e18
                        return {
                            "balance": eth_value, "balance_str": f"{eth_value:.18f}",
                            "chain": chain, "address": address,
                        }
        except Exception:
            continue
    return None


async def check_btc_balance(address: str, session) -> Optional[dict]:
    try:
        url = f"{settings.BLOCKSTREAM_API}/address/{address}"
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                funded = sum(u["value"] for u in data.get("chain_stats", {}).get("funded_txo_sum", 0))
                spent = sum(u["value"] for u in data.get("chain_stats", {}).get("spent_txo_sum", 0))
                btc_value = (funded - spent) / 1e8
                return {"balance": btc_value, "balance_str": f"{btc_value:.8f}", "chain": "btc", "address": address}
    except Exception:
        pass
    return None


async def check_sol_balance(address: str, session) -> Optional[dict]:
    try:
        payload = {"jsonrpc": "2.0", "method": "getBalance", "params": [address], "id": 1}
        async with session.post(settings.SOLANA_RPC, json=payload,
                                 timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                if data.get("result"):
                    sol_value = data["result"]["value"] / 1e9
                    return {"balance": sol_value, "balance_str": f"{sol_value:.9f}", "chain": "sol", "address": address}
    except Exception:
        pass
    return None


async def check_trx_balance(address: str, session) -> Optional[dict]:
    try:
        url = f"{settings.TRON_GRID_API}/v1/accounts/{address}"
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
            if resp.status == 200:
                data = await resp.json()
                if data.get("data") and len(data["data"]) > 0:
                    account = data["data"][0]
                    trx_balance = int(account.get("balance", 0)) / 1e6
                    tokens = []
                    for asset in account.get("v2", []):
                        if int(asset.get("balance", 0)) > 0:
                            tokens.append({"symbol": asset.get("symbol", "TRC20"), "balance": str(int(asset["balance"]) / 1e6)})
                    return {"balance": trx_balance, "balance_str": f"{trx_balance:.6f}", "chain": "trx", "address": address, "tokens": tokens}
    except Exception:
        pass
    return None


async def check_balances_async(job_id: int, chains: list, concurrency: int):
    db = get_db()
    all_checks = []
    for chain in chains:
        addrs = db.query(Address).filter(Address.chain == chain, Address.checked == False).all()
        for a in addrs:
            all_checks.append((chain, a.address, a.id))
    db.close()

    total = len(all_checks)
    if total == 0:
        return

    semaphore = asyncio.Semaphore(concurrency)

    async def _check(chain, address, addr_id, session):
        async with semaphore:
            if chain in settings.EVM_CHAINS:
                return addr_id, await check_single_evm_balance(chain, address, session)
            elif chain == "btc":
                return addr_id, await check_btc_balance(address, session)
            elif chain == "sol":
                return addr_id, await check_sol_balance(address, session)
            elif chain == "trx":
                return addr_id, await check_trx_balance(address, session)
            return addr_id, None

    connector = aiohttp.TCPConnector(limit=concurrency, limit_per_host=concurrency // 2)
    timeout = aiohttp.ClientTimeout(total=30)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        tasks = [_check(c, a, i, session) for c, a, i in all_checks]
        chunk_size = max(50, concurrency * 2)

        for i in range(0, len(tasks), chunk_size):
            chunk = tasks[i:i + chunk_size]
            results = await asyncio.gather(*chunk, return_exceptions=True)

            db = get_db()
            job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
            if not job or job.status in ("cancelled",):
                if job:
                    job.status = "cancelled"
                    db.commit()
                db.close()
                return

            for addr_id, res in results:
                if isinstance(res, Exception) or res is None:
                    continue
                addr_obj = db.query(Address).filter(Address.id == addr_id).first()
                if not addr_obj:
                    continue
                addr_obj.checked = True
                addr_obj.balance = res["balance_str"]
                addr_obj.balance_float = res["balance"]
                addr_obj.last_check = datetime.now(timezone.utc)
                addr_obj.has_funds = res["balance"] > settings.MIN_BALANCE_THRESHOLD
                if "tokens" in res and res.get("tokens"):
                    addr_obj.set_token_info({"tokens": res["tokens"]})
                job.checked_count = (job.checked_count or 0) + 1

            found_count = db.query(func.count(Address.id)).filter(Address.has_funds == True).scalar()
            job.found_count = found_count
            job.current_phase = "checking"
            checked = job.checked_count or 0
            job.current_message = f"Checking: {checked}/{total} ({found_count} found)"
            db.commit()
            db.close()

            await asyncio.sleep(0.1)

    db = get_db()
    job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
    if job:
        job.status = "completed"
        job.current_phase = "done"
        job.current_message = f"Scan complete! Found {job.found_count} wallets with funds."
        job.completed_at = datetime.now(timezone.utc)
        db.commit()
    db.close()


class ScanManager:
    def __init__(self):
        self._running_tasks = {}

    async def start_scan(self, job_id: int, chains: list, concurrency: int = 10):
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

        mnemonics = db.query(Mnemonic).filter(Mnemonic.status == "pending").all()
        mnemonic_texts = [m.mnemonic for m in mnemonics]
        db.close()

        if mnemonic_texts:
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, derive_addresses_batch, mnemonic_texts, job_id)

        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if not job or job.status == "cancelled":
            db.close()
            return
        job.status = "running_checking"
        db.commit()
        db.close()

        await check_balances_async(job_id, chains, concurrency)

    def stop_scan(self, job_id: int):
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        if job and job.status in ("running_derivation", "running_checking"):
            job.status = "cancelled"
            job.current_message = "Cancelled by user"
            db.commit()
        db.close()

    def get_job_status(self, job_id: int) -> Optional[dict]:
        db = get_db()
        job = db.query(ScanJob).filter(ScanJob.id == job_id).first()
        return job.to_dict() if job else None
        db.close()

    def get_all_jobs(self, limit=20):
        db = get_db()
        jobs = db.query(ScanJob).order_by(ScanJob.created_at.desc()).limit(limit).all()
        return [j.to_dict() for j in jobs]
        db.close()

    def get_results(self, job_id=None, chain=None, min_balance=0, page=1, per_page=50):
        db = get_db()
        query = db.query(Address).filter(Address.has_funds == True)
        if job_id:
            query = query.join(Mnemonic).filter(Address.mnemonic_id == Mnemonic.id, ScanJob.id == job_id)
        if chain:
            query = query.filter(Address.chain == chain)
        if min_balance > 0:
            query = query.filter(Address.balance_float >= min_balance)

        total = query.count()
        query = query.order_by(Address.balance_float.desc()).offset((page - 1) * per_page).limit(per_page)
        addresses = query.all()

        results = []
        for addr in addresses:
            mnemo = addr.mnemonic
            words = mnemo.mnemonic.split() if mnemo else []
            masked = " ".join(words[:4]) + "..." if len(words) > 4 else (mnemo.mnemonic if mnemo else "")
            results.append({
                "id": addr.id, "mnemonic": masked, "chain": addr.chain,
                "chain_name": settings.CHAIN_NAMES.get(addr.chain, addr.chain),
                "address": addr.address, "balance": addr.balance,
                "balance_float": addr.balance_float,
                "derivation_path": addr.derivation_path,
                "token_info": addr.get_token_info(),
                "last_check": addr.last_check.isoformat() if addr.last_check else "",
            })
        db.close()
        return {"total": total, "page": page, "per_page": per_page,
                "total_pages": (total + per_page - 1) // per_page, "results": results}

    def export_results(self, job_id=None, chain=None, min_balance=0):
        db = get_db()
        query = db.query(Address).filter(Address.has_funds == True)
        if job_id:
            query = query.join(Mnemonic).filter(Address.mnemonic_id == Mnemonic.id, ScanJob.id == job_id)
        if chain:
            query = query.filter(Address.chain == chain)
        if min_balance > 0:
            query = query.filter(Address.balance_float >= min_balance)

        results = []
        for addr in query.order_by(Address.balance_float.desc()).all():
            results.append({
                "mnemonic": addr.mnemonic.mnemonic, "chain": addr.chain,
                "chain_name": settings.CHAIN_NAMES.get(addr.chain, addr.chain),
                "address": addr.address, "balance": addr.balance,
                "derivation_path": addr.derivation_path,
            })
        db.close()
        return results


scan_manager = ScanManager()
PYEOF

# --- app/main.py ---
cat > app/main.py << 'PYEOF'
"""FastAPI application - routes, templates, and server setup."""

import json
import logging
import os
import asyncio
import csv
import io
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import func

from app.config import settings
from app.database import init_db, get_db, Mnemonic, Address, ScanJob
from app.scanner import scan_manager

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI(title="助记词批量扫描工具", version="1.0.0")

os.makedirs(settings.UPLOAD_DIR, exist_ok=True)
os.makedirs("data", exist_ok=True)

templates_dir = Path(__file__).parent / "templates"
templates = Jinja2Templates(directory=str(templates_dir))

static_dir = Path(__file__).parent / "static"
static_dir.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


@app.on_event("startup")
async def on_startup():
    init_db()
    logger.info("Database initialized")


# ===== Web Pages =====

@app.get("/", response_class=HTMLResponse)
async def index_page(request: Request):
    jobs = scan_manager.get_all_jobs(limit=10)
    return templates.TemplateResponse("index.html", {"request": request, "jobs": jobs, "chains": settings.CHAIN_NAMES})


@app.get("/upload", response_class=HTMLResponse)
async def upload_page(request: Request):
    return templates.TemplateResponse("upload.html", {
        "request": request, "chains": settings.CHAIN_NAMES,
        "max_size": settings.MAX_UPLOAD_SIZE_MB,
    })


@app.get("/scan/{job_id}", response_class=HTMLResponse)
async def scan_detail_page(request: Request, job_id: int):
    job = scan_manager.get_job_status(job_id)
    if not job:
        return HTMLResponse("Job not found", status_code=404)
    return templates.TemplateResponse("scan_detail.html", {
        "request": request, "job": job, "chains": settings.CHAIN_NAMES,
    })


@app.get("/results", response_class=HTMLResponse)
async def results_page(request: Request, job_id: int = Query(None),
                        chain: str = Query(None), page: int = Query(1)):
    data = scan_manager.get_results(job_id=job_id, chain=chain, page=page)
    return templates.TemplateResponse("results.html", {
        "request": request, "data": data,
        "chains": settings.CHAIN_NAMES,
        "current_chain": chain or "", "current_job_id": job_id or "",
    })


# ===== API =====

@app.post("/api/upload")
async def api_upload(file: UploadFile = File(...)):
    if not file.filename.endswith(".txt"):
        raise HTTPException(status_code=400, detail="Only .txt files are supported")

    content = await file.read()
    text = content.decode("utf-8", errors="ignore")

    lines = text.splitlines()
    mnemonics = []
    skipped = 0

    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        words = line.split()
        if len(words) not in (12, 15, 18, 21, 24):
            skipped += 1
            continue
        mnemonics.append(line.lower())

    if not mnemonics:
        raise HTTPException(status_code=400, detail="No valid mnemonics found")

    db = get_db()
    imported = 0
    for m in mnemonics:
        existing = db.query(Mnemonic).filter(Mnemonic.mnemonic == m).first()
        if not existing:
            db.add(Mnemonic(mnemonic=m))
            imported += 1
    db.commit()
    pending = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()
    db.close()

    return {"success": True, "imported": imported, "skipped": skipped,
            "pending": pending,
            "message": f"Imported {imported} mnemonics, skipped {skipped} invalid. Pending: {pending}"}


@app.post("/api/scan/start")
async def api_start_scan(chains: str = Form(...), concurrency: int = Form(10)):
    chain_list = json.loads(chains)
    if not chain_list:
        raise HTTPException(status_code=400, detail="Select at least one chain")
    for c in chain_list:
        if c not in settings.CHAIN_NAMES:
            raise HTTPException(status_code=400, detail=f"Unknown chain: {c}")

    db = get_db()
    total = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()
    if total == 0:
        db.close()
        raise HTTPException(status_code=400, detail="No pending mnemonics. Upload some first!")

    job = ScanJob(status="pending", total_mnemonics=total, concurrency=concurrency)
    job.set_chains(chain_list)
    db.add(job)
    db.commit()
    job_id = job.id
    db.close()

    asyncio.create_task(scan_manager.start_scan(job_id, chain_list, concurrency))
    return {"success": True, "job_id": job_id, "total_mnemonics": total}


@app.post("/api/scan/{job_id}/stop")
async def api_stop_scan(job_id: int):
    scan_manager.stop_scan(job_id)
    return {"success": True}


@app.get("/api/scan/{job_id}/status")
async def api_scan_status(job_id: int):
    job = scan_manager.get_job_status(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


@app.get("/api/scan/{job_id}/stream")
async def api_scan_stream(job_id: int, request: Request):
    async def event_generator():
        last_msg = ""
        while True:
            if await request.is_disconnected():
                break
            job = scan_manager.get_job_status(job_id)
            if not job:
                yield f"data: {json.dumps({'error': 'Job not found'})}\n\n"
                break
            msg = json.dumps(job)
            if msg != last_msg:
                yield f"data: {msg}\n\n"
                last_msg = msg
            if job["status"] in ("completed", "cancelled", "error"):
                break
            await asyncio.sleep(1)

    return StreamingResponse(event_generator(), media_type="text/event-stream",
                              headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                                       "X-Accel-Buffering": "no"})


@app.get("/api/jobs")
async def api_list_jobs():
    return scan_manager.get_all_jobs()


@app.get("/api/results")
async def api_results(job_id: int = Query(None), chain: str = Query(None),
                       page: int = Query(1), per_page: int = Query(50)):
    return scan_manager.get_results(job_id=job_id, chain=chain, page=page, per_page=per_page)


@app.get("/api/results/export")
async def api_export_results(job_id: int = Query(None), chain: str = Query(None), fmt: str = Query("csv")):
    results = scan_manager.export_results(job_id=job_id, chain=chain)
    if fmt == "json":
        return {"results": results}
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["助记词", "链", "链名称", "地址", "余额", "派生路径"])
    for r in results:
        writer.writerow([r["mnemonic"], r["chain"], r["chain_name"], r["address"], r["balance"], r["derivation_path"]])
    return StreamingResponse(iter([output.getvalue()]), media_type="text/csv",
                              headers={"Content-Disposition": f"attachment; filename=found_wallets_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"})


@app.get("/api/stats")
async def api_stats():
    db = get_db()
    total_m = db.query(func.count(Mnemonic.id)).scalar()
    derived = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "derived").scalar()
    pending = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "pending").scalar()
    errors = db.query(func.count(Mnemonic.id)).filter(Mnemonic.status == "error").scalar()
    found = db.query(func.count(Address.id)).filter(Address.has_funds == True).scalar()
    total_addr = db.query(func.count(Address.id)).scalar()
    checked = db.query(func.count(Address.id)).filter(Address.checked == True).scalar()

    chain_stats = {}
    for key, name in settings.CHAIN_NAMES.items():
        count = db.query(func.count(Address.id)).filter(Address.chain == key).scalar()
        f_count = db.query(func.count(Address.id)).filter(Address.chain == key, Address.has_funds == True).scalar()
        if count:
            chain_stats[key] = {"name": name, "addresses": count, "found": f_count}
    db.close()

    return {"mnemonics": {"total": total_m, "derived": derived, "pending": pending, "errors": errors},
            "addresses": {"total": total_addr, "checked": checked, "found": found},
            "chains": chain_stats}


def run():
    import uvicorn
    uvicorn.run("app.main:app", host=settings.HOST, port=settings.PORT, workers=1, log_level="info")
PYEOF

# --- wsgi.py ---
cat > wsgi.py << 'PYEOF'
"""Entry for uvicorn."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app.database import init_db
from app.main import app
init_db()
PYEOF

# --- Templates ---
cat > app/templates/base.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}助记词批量扫描工具{% endblock %}</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css" rel="stylesheet">
    <style>
        body { background: #0f0f1a; color: #e0e0e0; min-height: 100vh; }
        .navbar { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); border-bottom: 1px solid #2a2a4a; }
        .navbar-brand { color: #00d4aa !important; font-weight: 700; }
        .card { background: #1a1a2e; border: 1px solid #2a2a4a; border-radius: 12px; }
        .card-header { background: rgba(255,255,255,0.03); border-bottom: 1px solid #2a2a4a; font-weight: 600; }
        .btn-primary { background: #00d4aa; border-color: #00d4aa; color: #0f0f1a; font-weight: 600; }
        .btn-primary:hover { background: #00b894; border-color: #00b894; color: #0f0f1a; }
        .progress { height: 10px; border-radius: 5px; background: #2a2a4a; }
        .progress-bar { background: linear-gradient(90deg, #00d4aa, #00b894); transition: width 0.5s ease; }
        .progress-bar.stage-2 { background: linear-gradient(90deg, #667eea, #764ba2); }
        .badge-chain { font-size: 0.8rem; padding: 4px 10px; border-radius: 20px; }
        .badge-eth { background: #627eea; color: #fff; }
        .badge-bsc { background: #f0b90b; color: #1a1a2e; }
        .badge-btc { background: #f7931a; color: #1a1a2e; }
        .badge-sol { background: #9945ff; color: #fff; }
        .badge-trx { background: #ef0027; color: #fff; }
        .badge-polygon { background: #8247e5; color: #fff; }
        .badge-arbitrum { background: #2d374b; color: #fff; }
        .badge-optimism { background: #ff0420; color: #fff; }
        .table { color: #e0e0e0; }
        .table > :not(caption) > * > * { border-bottom-color: #2a2a4a; }
        .table-dark { --bs-table-bg: #1a1a2e; }
        .text-muted-light { color: #8888aa; }
        .upload-zone { border: 2px dashed #3a3a5a; border-radius: 16px; padding: 60px 20px; text-align: center; cursor: pointer; transition: all 0.3s; }
        .upload-zone:hover, .upload-zone.dragover { border-color: #00d4aa; background: rgba(0,212,170,0.05); }
        .upload-zone .icon { font-size: 3rem; color: #00d4aa; }
        .balance-positive { color: #00d4aa; font-weight: 600; }
        .chain-select-card { cursor: pointer; transition: all 0.2s; border: 2px solid #2a2a4a; }
        .chain-select-card:hover { border-color: #4a4a6a; }
        .chain-select-card.selected { border-color: #00d4aa; background: rgba(0,212,170,0.08); }
        .form-control, .form-select { background: #1a1a2e; border-color: #2a2a4a; color: #e0e0e0; }
        .form-control:focus, .form-select:focus { border-color: #00d4aa; box-shadow: 0 0 0 0.25rem rgba(0,212,170,0.15); }
        .pagination .page-link { background: #1a1a2e; border-color: #2a2a4a; color: #e0e0e0; }
        .pagination .page-item.active .page-link { background: #00d4aa; border-color: #00d4aa; color: #0f0f1a; }
        .stat-card { transition: transform 0.2s; }
        .stat-card:hover { transform: translateY(-2px); }
        a { color: #00d4aa; } a:hover { color: #00b894; }
        @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.5; } 100% { opacity: 1; } }
        .scanning-pulse { animation: pulse 1.5s infinite; }
        .footer { text-align: center; padding: 20px; color: #555577; font-size: 0.85rem; }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark">
        <div class="container">
            <a class="navbar-brand" href="/"><i class="bi bi-search-heart me-2"></i>助记词扫描器</a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item"><a class="nav-link" href="/"><i class="bi bi-speedometer2 me-1"></i>仪表盘</a></li>
                    <li class="nav-item"><a class="nav-link" href="/upload"><i class="bi bi-upload me-1"></i>上传</a></li>
                    <li class="nav-item"><a class="nav-link" href="/results"><i class="bi bi-wallet2 me-1"></i>结果</a></li>
                </ul>
            </div>
        </div>
    </nav>
    <div class="container py-4">{% block content %}{% endblock %}</div>
    <div class="footer"><i class="bi bi-shield-check me-1"></i>助记词批量扫描工具 v1.0 &mdash; 数据仅存储在本地服务器</div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
    {% block scripts %}{% endblock %}
</body>
</html>
HTMLEOF

cat > app/templates/index.html << 'HTMLEOF'
{% extends "base.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-12">
        <div class="d-flex justify-content-between align-items-center">
            <h3 class="mb-0"><i class="bi bi-speedometer2 me-2"></i>仪表盘</h3>
            <div>
                <a href="/upload" class="btn btn-primary me-2"><i class="bi bi-upload me-1"></i>上传助记词</a>
                <a href="/results" class="btn btn-outline-light"><i class="bi bi-wallet2 me-1"></i>查看结果</a>
            </div>
        </div>
    </div>
</div>
<div class="row g-3 mb-4" id="stats-container">
    <div class="col-md-3">
        <div class="card stat-card h-100"><div class="card-body text-center">
            <div class="text-muted-light mb-2"><i class="bi bi-file-text fs-4"></i></div>
            <div class="fs-2 fw-bold text-light" id="stat-total">-</div>
            <div class="text-muted-light">助记词总数</div>
        </div></div>
    </div>
    <div class="col-md-3">
        <div class="card stat-card h-100"><div class="card-body text-center">
            <div class="text-muted-light mb-2"><i class="bi bi-check-circle fs-4"></i></div>
            <div class="fs-2 fw-bold text-light" id="stat-derived">-</div>
            <div class="text-muted-light">已派生</div>
        </div></div>
    </div>
    <div class="col-md-3">
        <div class="card stat-card h-100"><div class="card-body text-center">
            <div class="text-muted-light mb-2"><i class="bi bi-clock fs-4"></i></div>
            <div class="fs-2 fw-bold text-light" id="stat-pending">-</div>
            <div class="text-muted-light">待处理</div>
        </div></div>
    </div>
    <div class="col-md-3">
        <div class="card stat-card h-100" style="border-color:#00d4aa;"><div class="card-body text-center">
            <div class="text-muted-light mb-2"><i class="bi bi-coin fs-4" style="color:#00d4aa;"></i></div>
            <div class="fs-2 fw-bold" style="color:#00d4aa;" id="stat-found">-</div>
            <div class="text-muted-light">有钱包地址</div>
        </div></div>
    </div>
</div>
<div class="row">
    <div class="col-12">
        <div class="card"><div class="card-header"><i class="bi bi-list-task me-1"></i>扫描任务历史</div>
        <div class="card-body">
            {% if jobs %}
            <div class="table-responsive">
                <table class="table table-dark table-hover mb-0">
                    <thead><tr><th>ID</th><th>状态</th><th>目标链</th><th>助记词</th><th>已派/已查/发现</th><th>进度</th><th>创建时间</th><th>操作</th></tr></thead>
                    <tbody>
                        {% for job in jobs %}
                        <tr>
                            <td>#{{ job.id }}</td>
                            <td>{% if job.status == 'completed' %}<span class="badge bg-success">完成</span>{% elif job.status in ('running_derivation','running_checking') %}<span class="badge bg-primary scanning-pulse">运行中</span>{% elif job.status == 'cancelled' %}<span class="badge bg-warning text-dark">已取消</span>{% elif job.status == 'error' %}<span class="badge bg-danger">错误</span>{% else %}<span class="badge bg-secondary">{{ job.status }}</span>{% endif %}</td>
                            <td>{% for c in job.chains %}<span class="badge badge-chain badge-{{ c }}">{{ c|upper }}</span> {% endfor %}</td>
                            <td>{{ job.total }}</td>
                            <td>{{ job.derived }}/{{ job.checked }}/<span class="balance-positive">{{ job.found }}</span></td>
                            <td style="width:150px;"><div class="progress"><div class="progress-bar {% if job.progress >= 50 %}stage-2{% endif %}" style="width:{{ job.progress }}%"></div></div><small class="text-muted-light">{{ job.progress }}%</small></td>
                            <td><small class="text-muted-light">{{ job.created_at[:19] if job.created_at else '-' }}</small></td>
                            <td>{% if job.status in ('running_derivation','running_checking') %}<a href="/scan/{{ job.id }}" class="btn btn-sm btn-outline-light">查看</a>{% elif job.status == 'completed' %}<a href="/results?job_id={{ job.id }}" class="btn btn-sm btn-outline-light">结果</a>{% endif %}</td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
            {% else %}
            <div class="text-center py-4">
                <i class="bi bi-inbox fs-1 text-muted-light"></i>
                <p class="text-muted-light mt-2 mb-3">还没有扫描任务</p>
                <a href="/upload" class="btn btn-primary"><i class="bi bi-upload me-1"></i>上传助记词开始</a>
            </div>
            {% endif %}
        </div></div>
    </div>
</div>
{% endblock %}
{% block scripts %}
<script>
async function loadStats(){try{const r=await fetch('/api/stats'),s=await r.json();document.getElementById('stat-total').textContent=s.mnemonics.total;document.getElementById('stat-derived').textContent=s.mnemonics.derived;document.getElementById('stat-pending').textContent=s.mnemonics.pending;document.getElementById('stat-found').textContent=s.addresses.found}catch(e){console.error(e)}}
loadStats();{% if jobs %}setInterval(loadStats,10000);{% endif %}
</script>
{% endblock %}
HTMLEOF

cat > app/templates/upload.html << 'HTMLEOF'
{% extends "base.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-12">
        <a href="/" class="btn btn-sm btn-outline-light mb-2"><i class="bi bi-arrow-left me-1"></i>返回</a>
        <h3><i class="bi bi-upload me-2"></i>上传助记词</h3>
        <p class="text-muted-light">上传 .txt 文件，每行一组助记词（12/15/18/21/24个单词）</p>
    </div>
</div>
<div class="row">
    <div class="col-lg-8">
        <div class="card mb-4"><div class="card-body">
            <div class="upload-zone" id="uploadZone" onclick="document.getElementById('fileInput').click()">
                <div class="icon mb-3"><i class="bi bi-cloud-upload"></i></div>
                <h5 class="text-light">拖拽文件到这里，或点击选择</h5>
                <p class="text-muted-light mb-0">支持 .txt 格式，最大 {{ max_size }}MB</p>
                <input type="file" id="fileInput" accept=".txt" style="display:none;">
            </div>
            <div id="upload-status" class="mt-3" style="display:none;"></div>
        </div></div>
        <div class="card" id="previewCard" style="display:none;"><div class="card-header d-flex justify-content-between align-items-center">
            <span><i class="bi bi-eye me-1"></i>文件预览</span>
            <span id="fileInfo" class="badge bg-secondary"></span>
        </div><div class="card-body"><pre id="previewContent" class="mb-0" style="max-height:200px;overflow-y:auto;color:#8888aa;font-size:0.85rem;"></pre></div></div>
        <div class="card mt-4" id="scanConfig" style="display:none;"><div class="card-header"><i class="bi bi-gear me-1"></i>配置扫描参数</div>
        <div class="card-body">
            <div class="mb-3">
                <label class="form-label fw-bold">选择目标链（至少选一个）</label>
                <div class="row g-2" id="chainSelector">
                    {% for key, name in chains.items() %}
                    <div class="col-md-3 col-6">
                        <div class="card chain-select-card text-center p-2 selected" data-chain="{{ key }}" onclick="toggleChain(this)">
                            <div class="py-1"><span class="badge-chain badge-{{ key }}">{{ key|upper }}</span><small class="d-block mt-1 text-muted-light">{{ name }}</small></div>
                        </div>
                    </div>
                    {% endfor %}
                </div>
            </div>
            <div class="row g-3"><div class="col-md-4">
                <label class="form-label">并发数</label>
                <select class="form-select" id="concurrency">
                    <option value="5">5</option><option value="10" selected>10</option><option value="20">20</option><option value="50">50</option>
                </select>
                <small class="text-muted-light">并发太高可能被 API 限流</small>
            </div></div>
            <button class="btn btn-primary btn-lg mt-3" onclick="startScan()"><i class="bi bi-play-fill me-1"></i>开始扫描</button>
        </div></div>
    </div>
    <div class="col-lg-4">
        <div class="card"><div class="card-header"><i class="bi bi-info-circle me-1"></i>使用说明</div>
        <div class="card-body">
            <ol class="mb-0 text-muted-light" style="line-height:2;">
                <li>准备 <strong>.txt</strong> 文件，每行一组助记词</li>
                <li>支持 12/15/18/21/24 个单词的标准 BIP39 格式</li>
                <li>上传后选择要检查的区块链</li>
                <li>点击"开始扫描"，实时查看进度</li>
                <li>扫描完成后在结果页导出 CSV/JSON</li>
            </ol>
            <hr class="text-muted"><p class="text-muted-light small mb-0"><i class="bi bi-shield-lock me-1"></i>所有数据仅存储在本服务器，不会外传</p>
        </div></div>
    </div>
</div>
{% endblock %}
{% block scripts %}
<script>
const zone=document.getElementById('uploadZone'),input=document.getElementById('fileInput');
zone.addEventListener('dragover',e=>{e.preventDefault();zone.classList.add('dragover')});
zone.addEventListener('dragleave',()=>{zone.classList.remove('dragover')});
zone.addEventListener('drop',e=>{e.preventDefault();zone.classList.remove('dragover');if(e.dataTransfer.files.length>0){input.files=e.dataTransfer.files;handleFile(e.dataTransfer.files[0])}});
input.addEventListener('change',()=>{if(input.files.length>0)handleFile(input.files[0])});
async function handleFile(file){if(!file.name.endsWith('.txt'))return alert('仅支持 .txt 文件');
const reader=new FileReader();reader.onload=function(e){const text=e.target.result,lines=text.split('\n').filter(l=>l.trim());document.getElementById('previewContent').textContent=lines.slice(0,10).join('\n')+(lines.length>10?`\n... 共 ${lines.length} 行`:'');
document.getElementById('fileInfo').textContent=`${lines.length} 行, ${(file.size/1024).toFixed(0)}KB`;document.getElementById('previewCard').style.display='block'};
reader.readAsText(file.slice(0,5000));
const s=document.getElementById('upload-status');s.style.display='block';s.innerHTML='<div class="alert alert-info"><i class="bi bi-arrow-repeat me-1"></i> 上传中...</div>';
const fd=new FormData();fd.append('file',file);
try{const r=await fetch('/api/upload',{method:'POST',body:fd}),d=await r.json();if(d.success){s.innerHTML=`<div class="alert alert-success"><i class="bi bi-check-circle me-1"></i> 上传成功！导入 <strong>${d.imported}</strong> 组，跳过 ${d.skipped} 行。待扫描: ${d.pending}</div>`;document.getElementById('scanConfig').style.display='block'}else s.innerHTML=`<div class="alert alert-danger">${d.detail||'上传失败'}</div>`}
catch(e){s.innerHTML=`<div class="alert alert-danger">上传出错: ${e.message}</div>`}}
function toggleChain(el){el.classList.toggle('selected')}
function getSelectedChains(){return Array.from(document.querySelectorAll('.chain-select-card.selected')).map(c=>c.dataset.chain)}
async function startScan(){const chains=getSelectedChains();if(!chains.length)return alert('请至少选择一条目标链');
const fd=new FormData();fd.append('chains',JSON.stringify(chains));fd.append('concurrency',document.getElementById('concurrency').value);
const btn=document.querySelector('button[onclick="startScan()"]');btn.disabled=true;btn.innerHTML='<span class="spinner-border spinner-border-sm me-1"></span> 启动中...';
try{const r=await fetch('/api/scan/start',{method:'POST',body:fd}),d=await r.json();if(d.success)window.location.href=`/scan/${d.job_id}`;else alert(d.detail||'启动失败')}catch(e){alert('请求失败: '+e.message)}
btn.disabled=false;btn.innerHTML='<i class="bi bi-play-fill me-1"></i>开始扫描'}
</script>
{% endblock %}
HTMLEOF

cat > app/templates/scan_detail.html << 'HTMLEOF'
{% extends "base.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-12">
        <a href="/" class="btn btn-sm btn-outline-light mb-2"><i class="bi bi-arrow-left me-1"></i>返回仪表盘</a>
        <h3><i class="bi bi-activity me-2"></i>扫描任务 #{{ job.id }}</h3>
    </div>
</div>
<div class="row">
    <div class="col-lg-8">
        <div class="card mb-4"><div class="card-body text-center py-5">
            <div id="statusIcon">{% if job.status in ('running_derivation','running_checking') %}<div class="spinner-border text-primary mb-3" style="width:3rem;height:3rem;"></div>{% elif job.status == 'completed' %}<i class="bi bi-check-circle text-success mb-3" style="font-size:3rem;"></i>{% elif job.status == 'cancelled' %}<i class="bi bi-stop-circle text-warning mb-3" style="font-size:3rem;"></i>{% elif job.status == 'error' %}<i class="bi bi-x-circle text-danger mb-3" style="font-size:3rem;"></i>{% else %}<i class="bi bi-hourglass text-secondary mb-3" style="font-size:3rem;"></i>{% endif %}</div>
            <h4 id="statusText">{% if job.status == 'running_derivation' %}正在派生地址...{% elif job.status == 'running_checking' %}正在检查余额...{% elif job.status == 'completed' %}扫描完成！{% elif job.status == 'cancelled' %}已取消{% elif job.status == 'error' %}扫描出错{% else %}等待开始...{% endif %}</h4>
            <p class="text-muted-light mb-0" id="statusMessage">{{ job.message }}</p>
        </div></div>
        <div class="card mb-4"><div class="card-header"><i class="bi bi-bar-chart me-1"></i>扫描进度 <span class="badge bg-secondary ms-2" id="progressPct">{{ job.progress }}%</span></div>
        <div class="card-body">
            <div class="progress mb-3" style="height:16px;"><div class="progress-bar {% if job.progress >= 50 %}stage-2{% endif %}" id="progressBar" style="width:{{ job.progress }}%;"></div></div>
            <div class="row text-center g-3">
                <div class="col-3"><div class="fs-4 fw-bold text-light" id="statTotal">{{ job.total }}</div><small class="text-muted-light">总计助记词</small></div>
                <div class="col-3"><div class="fs-4 fw-bold text-light" id="statDerived">{{ job.derived }}</div><small class="text-muted-light">已派生</small></div>
                <div class="col-3"><div class="fs-4 fw-bold text-light" id="statChecked">{{ job.checked }}</div><small class="text-muted-light">已检查</small></div>
                <div class="col-3"><div class="fs-4 fw-bold balance-positive" id="statFound">{{ job.found }}</div><small class="text-muted-light">有钱包</small></div>
            </div>
            <div class="mt-3"><span class="badge bg-secondary" id="phaseLabel">{% if job.phase == 'derivation' %}🔨 地址派生阶段{% elif job.phase == 'checking' %}🔍 余额检查阶段{% elif job.phase == 'done' %}✅ 已完成{% else %}⏳ 等待中{% endif %}</span>
            <span class="badge bg-info ms-2" id="errorCount" {% if job.errors==0 %}style="display:none;"{% endif %}>错误: {{ job.errors }}</span></div>
        </div></div>
        <div class="text-center mb-4" id="actionButtons">
            {% if job.status in ('running_derivation','running_checking') %}<button class="btn btn-danger" onclick="stopScan()"><i class="bi bi-stop-fill me-1"></i>停止扫描</button>
            {% elif job.status == 'completed' %}<a href="/results?job_id={{ job.id }}" class="btn btn-primary"><i class="bi bi-wallet2 me-1"></i>查看结果</a>
            <a href="/api/results/export?job_id={{ job.id }}" class="btn btn-outline-light ms-2"><i class="bi bi-download me-1"></i>导出 CSV</a>{% endif %}
        </div>
    </div>
    <div class="col-lg-4">
        <div class="card"><div class="card-header"><i class="bi bi-info-circle me-1"></i>任务信息</div>
        <div class="card-body">
            <table class="table table-dark table-borderless mb-0">
                <tr><td class="text-muted-light">任务 ID</td><td>#{{ job.id }}</td></tr>
                <tr><td class="text-muted-light">目标链</td><td>{% for c in job.chains %}<span class="badge badge-chain badge-{{ c }}">{{ c|upper }}</span> {% endfor %}</td></tr>
                <tr><td class="text-muted-light">并发数</td><td>{{ job.concurrency }}</td></tr>
                <tr><td class="text-muted-light">创建时间</td><td><small>{{ job.created_at[:19] if job.created_at else '-' }}</small></td></tr>
                <tr><td class="text-muted-light">开始时间</td><td><small id="startedAt">{{ job.started_at[:19] if job.started_at else '未开始' }}</small></td></tr>
            </table>
        </div></div>
    </div>
</div>
{% endblock %}
{% block scripts %}
<script>
const jobId={{ job.id }};
function connectSSE(){const s=new EventSource(`/api/scan/${jobId}/stream`);s.onmessage=function(e){try{updateUI(JSON.parse(e.data))}catch(e){}};s.onerror=function(){s.close()}}
function updateUI(d){document.getElementById('progressBar').style.width=d.progress+'%';document.getElementById('progressPct').textContent=d.progress+'%';document.getElementById('statTotal').textContent=d.total;document.getElementById('statDerived').textContent=d.derived;document.getElementById('statChecked').textContent=d.checked;document.getElementById('statFound').textContent=d.found;document.getElementById('statusMessage').textContent=d.message;if(d.errors>0){const e=document.getElementById('errorCount');e.style.display='inline';e.textContent='错误: '+d.errors}
const pl={'derivation':'🔨 地址派生阶段','checking':'🔍 余额检查阶段','done':'✅ 已完成'};document.getElementById('phaseLabel').textContent=pl[d.phase]||'⏳ '+d.phase;
const st={'running_derivation':'正在派生地址...','running_checking':'正在检查余额...','completed':'🎉 扫描完成！','cancelled':'已取消','error':'扫描出错'};document.getElementById('statusText').textContent=st[d.status]||d.status;
if(d.status==='completed'){document.getElementById('statusIcon').innerHTML='<i class="bi bi-check-circle text-success mb-3" style="font-size:3rem;"></i>';document.getElementById('actionButtons').innerHTML=`<a href="/results?job_id=${jobId}" class="btn btn-primary"><i class="bi bi-wallet2 me-1"></i>查看结果</a><a href="/api/results/export?job_id=${jobId}" class="btn btn-outline-light ms-2"><i class="bi bi-download me-1"></i>导出 CSV</a>`}
else if(d.status==='cancelled'||d.status==='error'){document.getElementById('statusIcon').innerHTML=d.status==='cancelled'?'<i class="bi bi-stop-circle text-warning mb-3" style="font-size:3rem;"></i>':'<i class="bi bi-x-circle text-danger mb-3" style="font-size:3rem;"></i>';document.getElementById('actionButtons').innerHTML='<a href="/upload" class="btn btn-primary"><i class="bi bi-upload me-1"></i>重新上传</a>'}
if(d.started_at)document.getElementById('startedAt').textContent=d.started_at.slice(0,19)}
async function stopScan(){if(!confirm('确定停止扫描？'))return;try{await fetch(`/api/scan/${jobId}/stop`,{method:'POST'})}catch(e){}}
{% if job.status in ('running_derivation','running_checking') %}connectSSE();{% endif %}
</script>
{% endblock %}
HTMLEOF

cat > app/templates/results.html << 'HTMLEOF'
{% extends "base.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-12">
        <a href="/" class="btn btn-sm btn-outline-light mb-2"><i class="bi bi-arrow-left me-1"></i>返回</a>
        <div class="d-flex justify-content-between align-items-center">
            <h3 class="mb-0"><i class="bi bi-wallet2 me-2"></i>有钱包地址</h3>
            <div>
                <a href="/api/results/export?{% if current_job_id %}job_id={{ current_job_id }}&{% endif %}{% if current_chain %}chain={{ current_chain }}&{% endif %}fmt=csv" class="btn btn-outline-light btn-sm"><i class="bi bi-download me-1"></i>导出 CSV</a>
                <a href="/api/results/export?{% if current_job_id %}job_id={{ current_job_id }}&{% endif %}{% if current_chain %}chain={{ current_chain }}&{% endif %}fmt=json" class="btn btn-outline-light btn-sm ms-1"><i class="bi bi-download me-1"></i>导出 JSON</a>
            </div>
        </div>
    </div>
</div>
<div class="card mb-4"><div class="card-body">
    <form method="GET" class="row g-3 align-items-end">
        <div class="col-md-3">
            <label class="form-label">链</label>
            <select name="chain" class="form-select" onchange="this.form.submit()">
                <option value="">全部</option>
                {% for key, name in chains.items() %}
                <option value="{{ key }}" {% if current_chain == key %}selected{% endif %}>{{ name }}</option>
                {% endfor %}
            </select>
        </div>
        <div class="col-md-2">
            <label>&nbsp;</label>
            <button type="submit" class="btn btn-primary w-100"><i class="bi bi-funnel me-1"></i>筛选</button>
        </div>
    </form>
</div></div>
<div class="card"><div class="card-header d-flex justify-content-between align-items-center">
    <span><i class="bi bi-list me-1"></i>发现 <strong>{{ data.total }}</strong> 个有钱包地址</span>
    <span class="text-muted-light small">页 {{ data.page }}/{{ data.total_pages }}</span>
</div>
<div class="card-body p-0">
    {% if data.results|length > 0 %}
    <div class="table-responsive">
        <table class="table table-dark table-hover mb-0">
            <thead><tr><th>#</th><th>链</th><th>地址</th><th>余额</th><th>助记词（前4词）</th><th>派生路径</th><th>检查时间</th></tr></thead>
            <tbody>
                {% for r in data.results %}
                <tr>
                    <td>{{ r.id }}</td>
                    <td><span class="badge badge-chain badge-{{ r.chain }}">{{ r.chain_name }}</span></td>
                    <td style="max-width:200px;"><code style="color:#e0e0e0;font-size:0.85rem;word-break:break-all;">{{ r.address }}</code></td>
                    <td class="balance-positive">{{ r.balance }}</td>
                    <td><small class="text-muted-light">{{ r.mnemonic }}</small></td>
                    <td><small class="text-muted-light">{{ r.derivation_path }}</small></td>
                    <td><small class="text-muted-light">{{ r.last_check[:19] if r.last_check else '-' }}</small></td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
    {% if data.total_pages > 1 %}
    <div class="d-flex justify-content-center py-3">
        <nav><ul class="pagination pagination-sm">
            {% if data.page > 1 %}<li class="page-item"><a class="page-link" href="?page={{ data.page-1 }}{% if current_chain %}&chain={{ current_chain }}{% endif %}{% if current_job_id %}&job_id={{ current_job_id }}{% endif %}">上一页</a></li>{% endif %}
            {% for p in range(1,data.total_pages+1) %}{% if p==data.page %}<li class="page-item active"><span class="page-link">{{ p }}</span></li>{% elif p<=3 or p>data.total_pages-3 or (p>=data.page-2 and p<=data.page+2) %}<li class="page-item"><a class="page-link" href="?page={{ p }}{% if current_chain %}&chain={{ current_chain }}{% endif %}{% if current_job_id %}&job_id={{ current_job_id }}{% endif %}">{{ p }}</a></li>{% endif %}{% endfor %}
            {% if data.page < data.total_pages %}<li class="page-item"><a class="page-link" href="?page={{ data.page+1 }}{% if current_chain %}&chain={{ current_chain }}{% endif %}{% if current_job_id %}&job_id={{ current_job_id }}{% endif %}">下一页</a></li>{% endif %}
        </ul></nav>
    </div>
    {% endif %}
    {% else %}
    <div class="text-center py-5">
        <i class="bi bi-inbox fs-1 text-muted-light"></i>
        <p class="text-muted-light mt-2">还没有找到有钱包地址</p>
        <a href="/upload" class="btn btn-primary"><i class="bi bi-upload me-1"></i>上传助记词</a>
    </div>
    {% endif %}
</div></div>
{% endblock %}
HTMLEOF

# --- static/style.css ---
touch app/static/style.css

# 4. 安装 Python 依赖
echo "[4/5] 安装 Python 依赖..."
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q

echo "[5/5] 启动服务..."
cat > /tmp/mn-scanner.service << 'SERVICEEOF'
[Unit]
Description=Mnemonic Scanner Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/mnemonic-scanner
ExecStart=/home/ubuntu/mnemonic-scanner/venv/bin/uvicorn wsgi:app --host 0.0.0.0 --port 8000 --workers 1 --log-level info
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICEEOF

sudo mv /tmp/mn-scanner.service /etc/systemd/system/mnemonic-scanner.service
sudo systemctl daemon-reload
sudo systemctl enable mnemonic-scanner
sudo systemctl restart mnemonic-scanner

echo ""
echo "========================================"
echo "  ✅ 部署完成！"
echo "========================================"
echo ""
echo "  访问地址: http://119.28.162.119:8000"
echo ""
echo "  管理命令:"
echo "    sudo systemctl status mnemonic-scanner"
echo "    sudo systemctl restart mnemonic-scanner"
echo "    sudo journalctl -u mnemonic-scanner -f"
echo ""
echo "  日志查看: tail -f ~/mnemonic-scanner/scanner.log"
echo "========================================"
