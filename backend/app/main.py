from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.logging import setup_logging
from app.routers import admin, devlog, feedback, pdf

setup_logging()


app = FastAPI(title="ScatchLM API", version="0.1.0")

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
