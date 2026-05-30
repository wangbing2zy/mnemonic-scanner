"""Database models using SQLAlchemy 2.0 + SQLite."""

import json
from datetime import datetime, timezone
from sqlalchemy import (
    create_engine, Column, Integer, String, Text, Float,
    Boolean, DateTime, ForeignKey, BigInteger, Index, text
)
from sqlalchemy.orm import DeclarativeBase, relationship, sessionmaker
from sqlalchemy.pool import NullPool

from app.config import settings


class Base(DeclarativeBase):
    pass


class Mnemonic(Base):
    """Stores mnemonic phrases and their derivation status."""
    __tablename__ = "mnemonics"

    id = Column(Integer, primary_key=True, autoincrement=True)
    mnemonic = Column(Text, unique=True, nullable=False, index=True)
    seed_hex = Column(Text, nullable=True)  # hex-encoded BIP39 seed
    status = Column(String(20), default="pending", index=True)  # pending, derived, error
    error_msg = Column(Text, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    addresses = relationship("Address", back_populates="mnemonic", cascade="all, delete-orphan")

    def __repr__(self):
        words = self.mnemonic.split() if self.mnemonic else []
        masked = " ".join(words[:4]) + "..." if len(words) > 4 else self.mnemonic
        return f"<Mnemonic {masked} ({self.status})>"


class Address(Base):
    """Derived addresses for each chain."""
    __tablename__ = "addresses"

    id = Column(Integer, primary_key=True, autoincrement=True)
    mnemonic_id = Column(Integer, ForeignKey("mnemonics.id", ondelete="CASCADE"), nullable=False, index=True)
    chain = Column(String(10), nullable=False, index=True)  # eth, bsc, btc, sol, trx
    address = Column(String(100), nullable=False)
    derivation_path = Column(String(50), nullable=True)
    balance = Column(String(50), default="0")  # String to avoid precision loss
    balance_float = Column(Float, default=0.0)  # Float for sorting/filtering
    checked = Column(Boolean, default=False, index=True)
    has_funds = Column(Boolean, default=False, index=True)
    token_info = Column(Text, nullable=True)  # JSON: discovered tokens/balances
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

    def __repr__(self):
        return f"<Address {self.chain}:{self.address[:12]}... bal={self.balance}>"


class ScanJob(Base):
    """Tracks scan job progress."""
    __tablename__ = "scan_jobs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    status = Column(String(20), default="pending", index=True)
    # pending, running_derivation, running_checking, running_generating, completed, cancelled, error

    chains = Column(Text, nullable=False, default="[]")  # JSON array
    concurrency = Column(Integer, default=10)
    min_balance = Column(String(20), default="0")

    total_mnemonics = Column(Integer, default=0)
    derived_count = Column(Integer, default=0)
    checked_count = Column(Integer, default=0)
    found_count = Column(Integer, default=0)
    error_count = Column(Integer, default=0)

    # For auto-generate mode
    generated_count = Column(Integer, default=0)
    generated_total = Column(Integer, default=0)  # 0 = unlimited
    stop_on_find = Column(Integer, default=0)  # boolean as int
    word_count = Column(Integer, default=12)  # 12 or 24
    speed = Column(Integer, default=0)  # generated/second

    current_phase = Column(String(50), nullable=True)  # derivation / checking / done
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
        """Calculate overall progress percentage."""
        if self.status in ("completed",):
            return 100.0

        if self.current_phase == "generating":
            if self.generated_total > 0:
                return round((self.generated_count / self.generated_total) * 100, 1)
            return 0.0

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
            "generated": self.generated_count,
            "generated_total": self.generated_total,
            "stop_on_find": self.stop_on_find,
            "word_count": self.word_count,
            "speed": self.speed,
            "phase": self.current_phase or "",
            "message": self.current_message or "",
            "progress": self.progress_pct(),
            "created_at": self.created_at.isoformat() if self.created_at else "",
            "started_at": self.started_at.isoformat() if self.started_at else "",
            "completed_at": self.completed_at.isoformat() if self.completed_at else "",
        }


# ---- Database setup ----

engine = None
SessionLocal = None


def init_db():
    """Initialize the database and create tables if they don't exist."""
    global engine, SessionLocal

    # Use sqlite directly for sync engine (background threads)
    sync_url = settings.DATABASE_URL.replace("+aiosqlite", "")
    engine = create_engine(
        sync_url,
        poolclass=NullPool,
        connect_args={"check_same_thread": False},
    )

    # Enable WAL mode for better concurrent performance
    with engine.connect() as conn:
        conn.execute(text("PRAGMA journal_mode=WAL"))
        conn.execute(text("PRAGMA synchronous=NORMAL"))
        conn.execute(text("PRAGMA cache_size=-8000"))  # 8MB cache
        conn.commit()

    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)

    return engine, SessionLocal


def get_db():
    """Get a new database session (sync, for background threads)."""
    if SessionLocal is None:
        init_db()
    return SessionLocal()


def get_async_db():
    """Get an async database session (for web routes)."""
    # For async routes we use aiosqlite, but for simplicity we return sync session
    # in thread pool executors.  FastAPI routes that need DB call sync code via
    # run_in_executor or use the sync session directly (SQLite is thread-safe with
    # check_same_thread=False and WAL mode).
    return get_db()
