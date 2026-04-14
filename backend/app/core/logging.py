import logging
import os
import sys

LOG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "logs")


def setup_logging() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)

    fmt = "%(asctime)s %(levelname)-8s [%(name)s] %(message)s"
    datefmt = "%Y-%m-%d %H:%M:%S"

    # 공통 포매터
    formatter = logging.Formatter(fmt, datefmt=datefmt)

    # stdout 핸들러
    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(formatter)

    # 전체 로그 파일
    all_handler = logging.FileHandler(os.path.join(LOG_DIR, "app.log"), encoding="utf-8")
    all_handler.setFormatter(formatter)

    # FE 전용 로그 파일
    fe_handler = logging.FileHandler(os.path.join(LOG_DIR, "fe.log"), encoding="utf-8")
    fe_handler.setFormatter(formatter)
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
