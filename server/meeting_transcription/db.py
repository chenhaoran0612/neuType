"""Database engine and session helpers for the meeting transcription service."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from sqlalchemy import MetaData, create_engine as sqlalchemy_create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

metadata = MetaData(naming_convention=NAMING_CONVENTION)
Base = declarative_base(metadata=metadata)


def enable_sqlite_foreign_keys(engine: Engine) -> None:
    """Enable SQLite foreign key enforcement for new DBAPI connections."""

    @event.listens_for(engine, "connect")
    def _set_sqlite_pragma(dbapi_connection: Any, connection_record: Any) -> None:
        del connection_record
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()


def create_engine(database_url: str, *, echo: bool = False) -> Engine:
    """Create a SQLAlchemy engine for the configured database URL."""
    is_sqlite = database_url.startswith("sqlite")
    connect_args: dict[str, Any] = {}
    if is_sqlite:
        connect_args["check_same_thread"] = False

    engine = sqlalchemy_create_engine(database_url, echo=echo, connect_args=connect_args)

    if is_sqlite:
        enable_sqlite_foreign_keys(engine)

    return engine


def create_session_factory(engine: Engine) -> sessionmaker[Session]:
    """Create a session factory bound to the provided engine."""
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


@contextmanager
def session_scope(session_factory: sessionmaker[Session]) -> Iterator[Session]:
    """Yield a database session with commit/rollback handling."""
    session = session_factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
