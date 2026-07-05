import io
from contextlib import asynccontextmanager
from datetime import date

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from PIL import Image
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from .claude import analyze_food_image
from .config import get_settings
from .db import Meal, get_session, init_db
from .schemas import Analysis, DailySummary, MealOut, MealUpdate

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="CalorieSnap API", version="1.0.0", lifespan=lifespan)


# --- Auth: optional bearer token, plus a per-request user id ---------------------
def require_auth(authorization: str | None = Header(default=None)) -> None:
    if not settings.api_key:
        return
    expected = f"Bearer {settings.api_key}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def get_user_id(x_user_id: str | None = Header(default=None)) -> str:
    return x_user_id or "default"


def to_jpeg(raw: bytes) -> bytes:
    """Normalise any uploaded image (incl. HEIC via client conversion) to JPEG,
    downscaled so we don't ship huge photos to the model."""
    img = Image.open(io.BytesIO(raw))
    img = img.convert("RGB")
    img.thumbnail((1536, 1536))
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85)
    return out.getvalue()


# --- Routes ----------------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/meals/analyze", response_model=MealOut, dependencies=[Depends(require_auth)])
async def analyze_and_log(
    image: UploadFile = File(...),
    logged_on: date | None = Form(default=None),
    volume_ml: float | None = Form(default=None),
    weight_grams: float | None = Form(default=None),
    tare_grams: float | None = Form(default=None),
    user_id: str = Depends(get_user_id),
    session: AsyncSession = Depends(get_session),
) -> Meal:
    """Take a food photo, estimate its nutrition with Claude, and log it.

    Portion signals the client may attach, best first:
      - `weight_grams`: total weight on the scale (plate + food).
      - `tare_grams`: known plate weight to subtract.
      - `volume_ml`: LiDAR-measured food volume.
    If a weight is supplied here we subtract the tare in code; otherwise the tare
    is passed to Claude so it can subtract from a scale reading it sees in the photo.
    """
    raw = await image.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty image")

    try:
        jpeg = to_jpeg(raw)
    except Exception:
        raise HTTPException(status_code=400, detail="Unsupported or corrupt image")

    net_weight: float | None = None
    if weight_grams is not None and weight_grams > 0:
        net_weight = max(weight_grams - (tare_grams or 0), 0)

    analysis: Analysis = await analyze_food_image(
        jpeg,
        volume_ml=volume_ml,
        weight_grams=net_weight,
        # Only hand the tare to Claude when we didn't already subtract it ourselves.
        tare_grams=tare_grams if net_weight is None else None,
    )

    # Effective food weight we end up recording (net entry, or what Claude read).
    effective_weight = net_weight
    if effective_weight is None and analysis.weight_grams_read > 0:
        effective_weight = analysis.weight_grams_read

    if analysis.total_calories <= 0 and not analysis.items:
        raise HTTPException(
            status_code=422,
            detail=analysis.notes or "No food detected in the photo",
        )

    meal = Meal(
        user_id=user_id,
        name=analysis.name,
        description="; ".join(f"{i.name} ({i.portion})" for i in analysis.items),
        calories=analysis.total_calories,
        protein_g=analysis.total_protein_g,
        carbs_g=analysis.total_carbs_g,
        fat_g=analysis.total_fat_g,
        confidence=analysis.confidence,
        volume_ml=volume_ml,
        weight_grams=effective_weight,
        logged_on=logged_on or date.today(),
    )
    session.add(meal)
    await session.commit()
    await session.refresh(meal)
    return meal


@app.get("/meals", response_model=list[MealOut], dependencies=[Depends(require_auth)])
async def list_meals(
    day: date | None = None,
    user_id: str = Depends(get_user_id),
    session: AsyncSession = Depends(get_session),
) -> list[Meal]:
    day = day or date.today()
    result = await session.execute(
        select(Meal)
        .where(Meal.user_id == user_id, Meal.logged_on == day)
        .order_by(Meal.created_at.desc())
    )
    return list(result.scalars().all())


@app.get(
    "/meals/summary",
    response_model=DailySummary,
    dependencies=[Depends(require_auth)],
)
async def daily_summary(
    day: date | None = None,
    goal: int | None = None,
    user_id: str = Depends(get_user_id),
    session: AsyncSession = Depends(get_session),
) -> DailySummary:
    day = day or date.today()
    goal = goal or settings.daily_calorie_goal
    result = await session.execute(
        select(Meal).where(Meal.user_id == user_id, Meal.logged_on == day)
    )
    meals = list(result.scalars().all())
    total = sum(m.calories for m in meals)
    return DailySummary(
        day=day,
        goal=goal,
        total_calories=total,
        total_protein_g=round(sum(m.protein_g for m in meals), 1),
        total_carbs_g=round(sum(m.carbs_g for m in meals), 1),
        total_fat_g=round(sum(m.fat_g for m in meals), 1),
        remaining=goal - total,
        meal_count=len(meals),
    )


@app.patch(
    "/meals/{meal_id}", response_model=MealOut, dependencies=[Depends(require_auth)]
)
async def update_meal(
    meal_id: int,
    patch: MealUpdate,
    user_id: str = Depends(get_user_id),
    session: AsyncSession = Depends(get_session),
) -> Meal:
    meal = await session.get(Meal, meal_id)
    if meal is None or meal.user_id != user_id:
        raise HTTPException(status_code=404, detail="Meal not found")
    for field, value in patch.model_dump(exclude_none=True).items():
        setattr(meal, field, value)
    await session.commit()
    await session.refresh(meal)
    return meal


@app.delete("/meals/{meal_id}", status_code=204, dependencies=[Depends(require_auth)])
async def delete_meal(
    meal_id: int,
    user_id: str = Depends(get_user_id),
    session: AsyncSession = Depends(get_session),
) -> None:
    result = await session.execute(
        delete(Meal).where(Meal.id == meal_id, Meal.user_id == user_id)
    )
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="Meal not found")
    await session.commit()
