from datetime import date, datetime

from pydantic import BaseModel, Field


class FoodItem(BaseModel):
    name: str
    portion: str = Field(description="Estimated portion, e.g. '1 cup', '200 g'")
    calories: int
    protein_g: float = 0
    carbs_g: float = 0
    fat_g: float = 0


class Analysis(BaseModel):
    """Raw result of analysing a food photo with Claude."""

    name: str = Field(description="Short label for the whole meal")
    items: list[FoodItem] = []
    total_calories: int
    total_protein_g: float = 0
    total_carbs_g: float = 0
    total_fat_g: float = 0
    weight_grams_read: float = 0
    confidence: float = Field(ge=0, le=1)
    notes: str = ""


class MealOut(BaseModel):
    id: int
    name: str
    description: str
    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float
    confidence: float
    volume_ml: float | None = None
    weight_grams: float | None = None
    logged_on: date
    created_at: datetime

    model_config = {"from_attributes": True}


class MealUpdate(BaseModel):
    """User correction of an AI estimate."""

    name: str | None = None
    calories: int | None = None
    protein_g: float | None = None
    carbs_g: float | None = None
    fat_g: float | None = None


class DailySummary(BaseModel):
    day: date
    goal: int
    total_calories: int
    total_protein_g: float
    total_carbs_g: float
    total_fat_g: float
    remaining: int
    meal_count: int
