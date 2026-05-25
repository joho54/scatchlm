from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgres@127.0.0.1:5433/scatchlm?ssl=disable"
    ANTHROPIC_API_KEY: str = ""
    SUPABASE_URL: str = ""
    SUPABASE_PUBLISHABLE_KEY: str = ""
    SUPABASE_SECRET_KEY: str = ""
    VOYAGE_API_KEY: str = ""
    PDF_UPLOAD_DIR: str = "uploads/pdf"
    MAX_PDF_SIZE_MB: int = 50
    DEBUG: bool = False

    # Storage: "local" (default) | "s3" (Naver Cloud Object Storage, S3 호환)
    STORAGE_BACKEND: str = "local"
    OBJECT_STORAGE_ENDPOINT: str = "https://kr.object.ncloudstorage.com"
    OBJECT_STORAGE_REGION: str = "kr-standard"
    OBJECT_STORAGE_BUCKET: str = ""
    OBJECT_STORAGE_ACCESS_KEY: str = ""
    OBJECT_STORAGE_SECRET_KEY: str = ""

    model_config = {"env_file": ".env"}


settings = Settings()
