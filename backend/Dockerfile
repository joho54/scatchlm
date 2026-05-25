FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# PyMuPDF/asyncpg 빌드용 시스템 의존성
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY . .

# 컨테이너 안에서는 로컬 업로드 디렉토리(스토리지 fallback)도 보장
RUN mkdir -p /app/uploads/pdf /app/logs

EXPOSE 18000

# alembic 마이그레이션 후 uvicorn 기동 (workers는 vCPU에 맞춰 조정)
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 18000 --workers 2 --loop uvloop"]
