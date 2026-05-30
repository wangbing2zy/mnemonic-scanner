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

    WEMIX_RPC: str = os.getenv("WEMIX_RPC", "https://api.wemix.com")

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
        "wemix": "WEMIX3.0",
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
        "wemix": [WEMIX_RPC],
    }

    # Chain BIP44 coin types
    CHAIN_BIP44: dict = {
        "eth": 60,
        "bsc": 60,      # BSC uses same path as ETH
        "polygon": 60,  # Polygon uses same path as ETH
        "arbitrum": 60,
        "optimism": 60,
        "wemix": 60,
        "btc": 0,
        "sol": 501,
        "trx": 195,
    }

    # Which chains are EVM-compatible
    EVM_CHAINS: set = {"eth", "bsc", "polygon", "arbitrum", "optimism", "wemix"}


settings = Settings()
