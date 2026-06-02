from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgres@127.0.0.1:5433/scatchlm?ssl=disable"
    ANTHROPIC_API_KEY: str = ""
    SUPABASE_URL: str = ""
    SUPABASE_PUBLISHABLE_KEY: str = ""
    SUPABASE_SECRET_KEY: str = ""
    # Supabase service-role 키 — Admin REST(auth 유저 삭제 등) 호출용. 절대 클라이언트 노출 금지.
    SUPABASE_SERVICE_ROLE_KEY: str = ""
    VOYAGE_API_KEY: str = ""
    PDF_UPLOAD_DIR: str = "uploads/pdf"
    MAX_PDF_SIZE_MB: int = 50
    DEBUG: bool = False

    # LLM 일일 비용 한도 (USD, tier별). 0/미설정 → 해당 tier 무제한. 윈도우는 KST 달력 일.
    DAILY_COST_LIMIT_NORMAL_USD: float = 0.0
    DAILY_COST_LIMIT_PRO_USD: float = 0.0

    # CORS 허용 오리진. 콤마 구분 문자열. 비어 있으면 와일드카드 없이 차단(iOS 네이티브는 CORS 무관).
    ALLOWED_ORIGINS: str = ""

    # 빌드 식별 (startup 로그 / 관측). 배포 시 git SHA 주입.
    APP_VERSION: str = "0.1.0"
    GIT_SHA: str = "dev"
    ENVIRONMENT: str = "dev"

    # Storage: "local" (default) | "s3" (Naver Cloud Object Storage, S3 호환)
    STORAGE_BACKEND: str = "local"
    OBJECT_STORAGE_ENDPOINT: str = "https://kr.object.ncloudstorage.com"
    OBJECT_STORAGE_REGION: str = "kr-standard"
    OBJECT_STORAGE_BUCKET: str = ""
    OBJECT_STORAGE_ACCESS_KEY: str = ""
    OBJECT_STORAGE_SECRET_KEY: str = ""

    model_config = {"env_file": ".env"}


settings = Settings()
