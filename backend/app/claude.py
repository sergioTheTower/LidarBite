"""Food-photo → nutrition estimate, using Claude's vision model.

We send the image plus a structured-output schema so Claude returns strict JSON
we can validate directly into the `Analysis` model.
"""

import base64
import json

from anthropic import AsyncAnthropic

from .config import get_settings
from .schemas import Analysis

settings = get_settings()
client = AsyncAnthropic(api_key=settings.anthropic_api_key)

SYSTEM_PROMPT = """You are a nutrition estimation assistant for a calorie-tracking app.
Given a photo of food, identify each distinct food item, estimate its portion size,
and estimate calories and macronutrients (protein, carbs, fat in grams).

Portion size — use the strongest signal available, in this order:
1. WEIGHT. If a kitchen/food scale display is visible in the photo, READ the number
   and its unit (g / oz / lb) and set `weight_grams_read` (converted to grams). A known
   weight is the most reliable portion signal — derive calories/macros from grams and the
   food's typical caloric density. If the caller also supplies a measured weight, that
   value is authoritative and overrides what you read.
2. VOLUME. If the caller supplies a LiDAR-measured volume, use it as a strong constraint.
3. VISUAL CUES. Otherwise gauge portion from plate/fork/hand references in the image.

Other guidance:
- Prefer typical/average preparations when the recipe is ambiguous.
- Sum the items into the meal totals.
- Set `confidence` between 0 and 1: highest (0.9+) when a weight is known, high (0.8) for
  clearly identifiable single items, lower (0.3-0.6) for mixed dishes or unclear portions.
- `weight_grams_read` must be 0 when no scale reading is visible.
- If the image contains no food, return total_calories 0, empty items, confidence 0,
  and explain in `notes`.
Be realistic, not optimistic. It is better to slightly over-estimate calories than under."""

# JSON schema for structured output (all objects need additionalProperties:false + required).
OUTPUT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "name": {"type": "string"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "name": {"type": "string"},
                    "portion": {"type": "string"},
                    "calories": {"type": "integer"},
                    "protein_g": {"type": "number"},
                    "carbs_g": {"type": "number"},
                    "fat_g": {"type": "number"},
                },
                "required": ["name", "portion", "calories", "protein_g", "carbs_g", "fat_g"],
            },
        },
        "total_calories": {"type": "integer"},
        "total_protein_g": {"type": "number"},
        "total_carbs_g": {"type": "number"},
        "total_fat_g": {"type": "number"},
        "weight_grams_read": {"type": "number"},
        "confidence": {"type": "number"},
        "notes": {"type": "string"},
    },
    "required": [
        "name",
        "items",
        "total_calories",
        "total_protein_g",
        "total_carbs_g",
        "total_fat_g",
        "weight_grams_read",
        "confidence",
        "notes",
    ],
}


async def analyze_food_image(
    image_bytes: bytes,
    media_type: str = "image/jpeg",
    volume_ml: float | None = None,
    weight_grams: float | None = None,
    tare_grams: float | None = None,
) -> Analysis:
    b64 = base64.standard_b64encode(image_bytes).decode("utf-8")

    prompt = "Analyze this meal and estimate its nutrition."
    have_weight = weight_grams is not None and weight_grams > 0
    have_volume = volume_ml is not None and volume_ml > 0
    have_tare = tare_grams is not None and tare_grams > 0

    if have_weight and have_volume:
        density = weight_grams / volume_ml  # g/mL
        prompt += (
            f" IMPORTANT MEASUREMENTS: the food was WEIGHED at ~{weight_grams:.0f} g and "
            f"its volume was measured with LiDAR at ~{volume_ml:.0f} mL, giving a density "
            f"of ~{density:.2f} g/mL. Use the WEIGHT as authoritative for portion size, "
            "and use the density as a strong clue to identify the food and its caloric "
            "density per gram (dense ~1+ g/mL suggests meat/cheese/sauce; light "
            "~0.2-0.4 g/mL suggests leafy/airy foods). Derive calories/macros from the "
            "weight and this composition."
        )
    elif have_weight:
        prompt += (
            f" IMPORTANT: the food was WEIGHED at approximately {weight_grams:.0f} g. "
            "Treat this as authoritative for portion size — identify the food, estimate "
            "its caloric density per gram, and derive calories/macros from the weight. "
            "Ignore any scale reading you see in the image in favour of this value."
        )
    elif have_volume:
        prompt += (
            f" IMPORTANT: the food's volume was MEASURED with a LiDAR depth sensor as "
            f"approximately {volume_ml:.0f} mL. Treat this as a reliable constraint on "
            "portion size — estimate the food's density and composition, then derive "
            "calories/macros consistent with this measured volume."
        )
    elif have_tare:
        prompt += (
            " If a kitchen scale display is visible, READ the total weight shown. The "
            f"plate/container weighs ~{tare_grams:.0f} g — SUBTRACT that from the reading "
            "to get the food's net weight, and use the net weight as the portion size. "
            "Set `weight_grams_read` to the net food weight (after subtraction)."
        )
    else:
        prompt += (
            " If a kitchen scale display is visible, read the weight and use it as the "
            "portion size."
        )

    response = await client.messages.create(
        model=settings.anthropic_model,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        output_config={"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}},
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": media_type,
                            "data": b64,
                        },
                    },
                    {"type": "text", "text": prompt},
                ],
            }
        ],
    )

    # With output_config.format the first text block is guaranteed-valid JSON.
    text = next(b.text for b in response.content if b.type == "text")
    return Analysis.model_validate(json.loads(text))
