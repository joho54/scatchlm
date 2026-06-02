import logging
import os
import sys
from logging.handlers import RotatingFileHandler

LOG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "logs")

# 로그 로테이션 — 디스크 풀 방지 (O2). 파일당 50MB, 5개 백업 = 핸들러당 최대 ~300MB.
_MAX_BYTES = 50 * 1024 * 1024
_BACKUP_COUNT = 5


def _rotating(path: str, formatter: logging.Formatter) -> RotatingFileHandler:
    handler = RotatingFileHandler(
        path, maxBytes=_MAX_BYTES, backupCount=_BACKUP_COUNT, encoding="utf-8"
    )
    handler.setFormatter(formatter)
    return handler


def setup_logging() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)

    from app.core.request_context import RequestContextFilter

    fmt = "%(asctime)s %(levelname)-8s [%(name)s] [trace:%(trace_id)s req:%(request_id)s] %(message)s"
    datefmt = "%Y-%m-%d %H:%M:%S"

    # 공통 포매터 + request_id 주입 필터
    formatter = logging.Formatter(fmt, datefmt=datefmt)
    ctx_filter = RequestContextFilter()

    # stdout 핸들러
    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(formatter)
    stdout_handler.addFilter(ctx_filter)

    # 전체 로그 파일 (로테이션)
    all_handler = _rotating(os.path.join(LOG_DIR, "app.log"), formatter)
    all_handler.addFilter(ctx_filter)

    # FE 전용 로그 파일 (로테이션)
    fe_handler = _rotating(os.path.join(LOG_DIR, "fe.log"), formatter)
    fe_handler.addFilter(ctx_filter)
    fe_logger = logging.getLogger("fe")
    fe_logger.addHandler(fe_handler)

    # 루트 로거 설정
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(stdout_handler)
    root.addHandler(all_handler)

    # 외부 라이브러리 노이즈 줄이기
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
