FROM python:3.12-slim

WORKDIR /app

# System deps for Pillow are already in the slim image for JPEG/PNG; no extras needed.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
