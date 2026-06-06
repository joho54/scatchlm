from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgres@127.0.0.1:5433/scatchlm?ssl=disable"
    ANTHROPIC_API_KEY: str = ""
    SUPABASE_URL: str = ""
    SUPABASE_PUBLISHABLE_KEY: str = ""
    # Supabase secret 키(신형, 옛 service_role) — Admin REST(auth 유저 삭제 등) 호출용. 절대 클라이언트 노출 금지.
    SUPABASE_SECRET_KEY: str = ""
    VOYAGE_API_KEY: str = ""
    # PDF 업로드 시 Voyage 임베딩 인덱싱(청킹+임베딩) 수행 여부.
    # 현재 RAG 검색 경로(feedback.py)는 PDF 텍스트 추출이 빈 경우에만 도달하는
    # degenerate fallback이라 임베딩 산출물이 사실상 소비되지 않는다. 매 업로드마다
    # 발생하는 Voyage 비용·지연을 없애기 위해 기본 비활성화. 되살리려면 true.
    ENABLE_EMBEDDING: bool = False
    PDF_UPLOAD_DIR: str = "uploads/pdf"
    MAX_PDF_SIZE_MB: int = 50
    DEBUG: bool = False

    # LLM 일일 비용 한도 (USD, tier별). 0/미설정 → 해당 tier 무제한. 윈도우는 KST 달력 일.
    DAILY_COST_LIMIT_NORMAL_USD: float = 0.0
    DAILY_COST_LIMIT_PRO_USD: float = 0.0

    # 스캔본(이미지) PDF OCR — docs/scanned-pdf-ocr-spec.md.
    # 기능 토글. 켜기 전 OCR 예산 한도(양수)를 반드시 설정할 것(§1.4 운영 리스크).
    ENABLE_OCR: bool = False
    # pro OCR 백그라운드 일일 예산(USD, task_type="ocr"만 합산). 0/미설정 → 무제한.
    DAILY_COST_LIMIT_OCR_PRO_USD: float = 0.0
    # free(normal) 권당(per-textbook) OCR 페이지 하드 캡.
    OCR_FREE_CAP_PAGES: int = 50
    # pro 권당 OCR 페이지 백스톱(잘못된 TOC로 거대 범위가 잡혀도 비용 캡).
    OCR_MAX_PAGES_PER_BOOK: int = 600

    # IAP (Apple StoreKit 2 구독). docs/iap-subscription-spec.md §4.1/§4.3.
    APPLE_BUNDLE_ID: str = "com.joho54.scatchlm"
    APPLE_IAP_PRODUCT_ID_PRO_MONTHLY: str = "com.joho54.scatchlm.pro.monthly"
    # 프로덕션 ASSN v2 알림 검증에 필요한 App Store "apple id"(숫자). 미설정이면 Sandbox만 검증 가능.
    APPLE_APP_APPLE_ID: int | None = None

    # CORS 허용 오리진. 콤마 구분 문자열. 비어 있으면 와일드카드 없이 차단(iOS 네이티브는 CORS 무관).
    ALLOWED_ORIGINS: str = ""

    # 빌드 식별 (startup 로그 / 관측). 배포 시 git SHA 주입.
    APP_VERSION: str = "0.1.0"
    GIT_SHA: str = "dev"
    ENVIRONMENT: str = "dev"

    # Sentry (에러/크래시 리포팅, O7). DSN 빈 값이면 SDK는 no-op(dev 안전).
    # release=scatchlm-backend@{GIT_SHA}, environment=ENVIRONMENT 재사용(신규 env 불필요).
    # traces_sample_rate=0이어도 trace_id 전파/상관은 유지(spec §3.1).
    SENTRY_DSN: str = ""
    SENTRY_TRACES_SAMPLE_RATE: float = 0.0

    # Storage: "local" (default) | "s3" (Naver Cloud Object Storage, S3 호환)
    STORAGE_BACKEND: str = "local"
    OBJECT_STORAGE_ENDPOINT: str = "https://kr.object.ncloudstorage.com"
    OBJECT_STORAGE_REGION: str = "kr-standard"
    OBJECT_STORAGE_BUCKET: str = ""
    OBJECT_STORAGE_ACCESS_KEY: str = ""
    OBJECT_STORAGE_SECRET_KEY: str = ""

    model_config = {"env_file": ".env"}


settings = Settings()
