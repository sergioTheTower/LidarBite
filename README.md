# CalorieSnap 📸🍽️

Take a photo of your food on your iPhone → a backend container on your Komodo
stack sends it to **Claude's vision model** → you get calories + macros logged to
Postgres, with daily totals against your goal.

```
iPhone (SwiftUI)  ──photo──▶  FastAPI container  ──▶  Claude vision (Anthropic API)
       ▲                            │
       └────── calories/macros ─────┘   stores meals in ─▶  Postgres
```

## What's in here

| Path | What it is |
|------|-----------|
| `backend/` | FastAPI app: `/meals/analyze`, `/meals`, `/meals/summary`, `/meals/{id}` |
| `docker-compose.yml` | Komodo-ready stack: API + Postgres |
| `ios/` | Native SwiftUI iPhone app |

## 1. Deploy the backend on Komodo

1. Get an Anthropic API key: https://console.anthropic.com → API keys.
2. In Komodo, create a **Stack** pointing at this repo's `docker-compose.yml`.
3. Set these environment variables on the stack (see `backend/.env.example`):
   - `ANTHROPIC_API_KEY` — your key
   - `POSTGRES_PASSWORD` — any strong password
   - `API_KEY` — a long random string (the iPhone app sends it as a bearer token)
   - `ANTHROPIC_MODEL` *(optional)* — `claude-opus-4-8` (default), or `claude-sonnet-5` /
     `claude-haiku-4-5` for lower cost
4. Deploy. The API listens on port `8000`. Put it behind your reverse proxy with
   HTTPS (recommended) so the iPhone can reach it as e.g. `https://calories.yourdomain.com`.

Quick local test:
```bash
cd backend
cp .env.example .env   # fill in values
docker compose -f ../docker-compose.yml up --build
curl localhost:8000/health          # {"status":"ok"}
```

## 2. Build the iPhone app

You install it on your own iPhone for free with a personal Apple ID — no paid
developer account needed for personal use.

1. Install XcodeGen and generate the project:
   ```bash
   brew install xcodegen
   cd ios && xcodegen
   open CalorieSnap.xcodeproj
   ```
   *(No XcodeGen? Create a new iOS App in Xcode, drag in `ios/CalorieSnap/*.swift`,
   and add the Info.plist keys from `ios/project.yml`.)*
2. In Xcode: select your iPhone, set **Signing → Team** to your Apple ID, run.
3. On first launch tap ⚙️ → set **Server URL** (your backend) and **API key**
   (must match `API_KEY` on the server).
4. Tap **Snap a meal**, point at your food, and it logs automatically.

## API reference

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/meals/analyze` | multipart `image` → runs Claude, logs the meal |
| GET  | `/meals?day=YYYY-MM-DD` | list a day's meals |
| GET  | `/meals/summary?day=…&goal=…` | daily totals vs goal |
| PATCH | `/meals/{id}` | correct a meal's calories/macros |
| DELETE | `/meals/{id}` | delete a meal |

All routes except `/health` require `Authorization: Bearer <API_KEY>` when
`API_KEY` is set. An optional `X-User-Id` header separates data per person
(defaults to `default`).

## How accurate is the calorie estimate?

Photo-based estimation is a **useful guide, not a food scale.** See below — the
short version: expect roughly ±20–30% on a typical plated meal, better for
single packaged items, worse for mixed dishes and hidden ingredients (oils,
sauces, sugar). The app surfaces the model's confidence and lets you tap-to-edit
any estimate, which is how you keep the running total honest.
