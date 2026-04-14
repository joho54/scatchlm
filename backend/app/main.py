from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.database import engine
from app.core.logging import setup_logging
from app.models.user import Base
import app.models.textbook  # noqa: F401
import app.models.usage  # noqa: F401
from app.routers import admin, devlog, feedback, pdf

setup_logging()


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield


app = FastAPI(title="ScatchLM API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # TODO: 배포 시 허용 도메인으로 제한 필요
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(feedback.router)
app.include_router(pdf.router)
app.include_router(admin.router)
app.include_router(devlog.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
