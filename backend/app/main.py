import asyncio
import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.core.config import settings
from app.core.database import async_session
from app.core.logging import setup_logging
from app.core.sentry import init_sentry
from app.middleware.request_log import RequestLogMiddleware
from app.routers import account, admin, devlog, discover, feedback, iap, pdf, sync
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
app.include_router(discover.router)
app.include_router(pdf.router)
app.include_router(admin.router)
app.include_router(devlog.router)
app.include_router(sync.router)
app.include_router(account.router)
app.include_router(iap.router)


# 422(요청 검증 실패) 가시화 — 기본 핸들러는 detail을 클라이언트로만 돌려주고 서버엔 안 남긴다.
# 미들웨어 access 로그도 status만 찍어 "무엇이 왜 거부됐는지"가 영영 기록되지 않았다.
# 어느 필드(errors)·어느 클라이언트(body/UA)가 거부됐는지 fe 로거에 남겨 디버깅 가능하게 한다.
_fe_log = logging.getLogger("fe")


@app.exception_handler(RequestValidationError)
async def _log_validation_error(request: Request, exc: RequestValidationError):
    try:
        raw = (await request.body()).decode("utf-8", "replace")
    except Exception:
        raw = "<body read failed>"
    _fe_log.warning(
        "422 %s ua=%r errors=%s body=%s",
        request.url.path,
        request.headers.get("user-agent", ""),
        exc.errors(),
        raw[:2000],
    )
    return JSONResponse(status_code=422, content={"detail": exc.errors()})


@app.on_event("startup")
async def _log_startup() -> None:
    log.info(
        "ScatchLM API startup: version=%s git=%s env=%s storage=%s origins=%s",
        settings.APP_VERSION, settings.GIT_SHA, settings.ENVIRONMENT,
        settings.STORAGE_BACKEND, _origins or "(none)",
    )
    # 스캔본 OCR 자동 재개 스위퍼 — 예산 회복(KST 자정)·예외·프로세스 사망 잡을 주기적으로 이어받는다.
    # 워커마다 기동되나 _background_ocr의 원자 claim으로 중복은 무해. ENABLE_OCR일 때만.
    if settings.ENABLE_OCR:
        from app.routers.pdf import _ocr_sweeper_loop
        app.state.ocr_sweeper_task = asyncio.create_task(_ocr_sweeper_loop())


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
