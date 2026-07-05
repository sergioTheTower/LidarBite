from collections.abc import AsyncGenerator
from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, Integer, String, func
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from .config import get_settings

settings = get_settings()

engine = create_async_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class Meal(Base):
    """A single logged meal (one photo → one AI estimate, editable by the user)."""

    __tablename__ = "meals"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[str] = mapped_column(String(128), index=True, default="default")

    name: Mapped[str] = mapped_column(String(256))
    description: Mapped[str] = mapped_column(String(1024), default="")

    calories: Mapped[int] = mapped_column(Integer)
    protein_g: Mapped[float] = mapped_column(Float, default=0)
    carbs_g: Mapped[float] = mapped_column(Float, default=0)
    fat_g: Mapped[float] = mapped_column(Float, default=0)

    # 0.0–1.0, how confident the model was in the estimate.
    confidence: Mapped[float] = mapped_column(Float, default=0)

    # LiDAR-measured food volume in mL, if the client provided one.
    volume_ml: Mapped[float | None] = mapped_column(Float, nullable=True)

    # Net food weight in grams (from a scale reading, tare subtracted), if known.
    weight_grams: Mapped[float | None] = mapped_column(Float, nullable=True)

    # The calendar day this meal counts toward (local date sent by the client).
    logged_on: Mapped[date] = mapped_column(Date, index=True, default=date.today)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


async def init_db() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session
