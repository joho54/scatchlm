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

    model_config = {"env_file": ".env"}


settings = Settings()
