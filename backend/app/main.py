from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core.database import engine
from app.core.logging import setup_logging
from app.models.user import Base
import app.models.textbook  # noqa: F401
import app.models.usage  # noqa: F401
from app.routers import admin, feedback, pdf

setup_logging()


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield


app = FastAPI(title="ScatchLM API", version="0.1.0", lifespan=lifespan)

app.include_router(feedback.router)
app.include_router(pdf.router)
app.include_router(admin.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
