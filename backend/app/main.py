import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.core.config import settings
from app.core.database import async_session
from app.core.logging import setup_logging
from app.core.sentry import init_sentry
from app.middleware.request_log import RequestLogMiddleware
from app.routers import account, admin, devlog, feedback, iap, pdf, sync
from app.services.storage import storage

setup_logging()
log = logging.getLogger(__name__)

# Sentry는 app 생성 전에 init해야 ASGI/FastAPI 통합이 올바르게 결선된다(spec §4.1·A-2).
init_sentry()


app = FastAPI(title="ScatchLM API", version=settings.APP_VERSION)

# 요청 로깅 미들웨어 (request_id 전파 + 전역 예외 핸들러).
app.add_middleware(RequestLogMiddleware)

# CORS — ALLOWED_ORIGINS env(콤마 구분)로 제한(L6). iOS 네이티브는 CORS 무관이라 빈 값도 정상.
_origins = [o.strip() for o in settings.ALLOWED_ORIGINS.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(feedback.router)
app.include_router(pdf.router)
app.include_router(admin.router)
app.include_router(devlog.router)
app.include_router(sync.router)
app.include_router(account.router)
app.include_router(iap.router)


@app.on_event("startup")
async def _log_startup() -> None:
    log.info(
        "ScatchLM API startup: version=%s git=%s env=%s storage=%s origins=%s",
        settings.APP_VERSION, settings.GIT_SHA, settings.ENVIRONMENT,
        settings.STORAGE_BACKEND, _origins or "(none)",
    )


@app.get("/health")
async def health():
    """의존성 readiness 체크 (§3.2-d). DB·storage 1개라도 실패 시 503."""
    db_ok = True
    storage_ok = True

    try:
        async with async_session() as session:
            await session.execute(text("SELECT 1"))
    except Exception:
        log.exception("health: DB check failed")
        db_ok = False

    try:
        # storage 헬스: 로컬은 디렉토리 접근, S3는 list 1건으로 확인.
        storage.list_keys("__healthcheck__/")
    except Exception:
        log.exception("health: storage check failed")
        storage_ok = False

    body = {
        "status": "ok" if (db_ok and storage_ok) else "degraded",
        "db": "ok" if db_ok else "error",
        "storage": "ok" if storage_ok else "error",
    }
    status_code = 200 if (db_ok and storage_ok) else 503
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=status_code, content=body)


@app.get("/health/live")
async def health_live():
    """liveness — 의존성 무관 정적 ok."""
    return {"status": "ok"}
