import uuid
from datetime import datetime, timezone

from sqlalchemy import String, Integer, DateTime, ForeignKey, Boolean
from sqlalchemy.orm import Mapped, mapped_column

from app.models.user import Base


class TextbookSource(Base):
    __tablename__ = "textbook_sources"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String, ForeignKey("users.id"), nullable=False)
    note_id: Mapped[str | None] = mapped_column(String, nullable=True)
    file_name: Mapped[str] = mapped_column(String, nullable=False)
    server_path: Mapped[str] = mapped_column(String, nullable=False)
    total_pages: Mapped[int] = mapped_column(Integer, nullable=False)
    file_size: Mapped[int] = mapped_column(Integer, nullable=False)
    content_hash: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    # 스캔본(이미지) PDF OCR 상태 — docs/scanned-pdf-ocr-spec.md §4.1-b.
    is_scanned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ocr_status: Mapped[str | None] = mapped_column(String, nullable=True)  # pending|running|paused|error|complete
    ocr_pages_done: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ocr_cap: Mapped[int | None] = mapped_column(Integer, nullable=True)  # 이 책에 적용된 페이지 천장 (=min(total, OCR_MAX_PAGES_PER_FILE))
    # OCR을 *처음* 시작한 시각(최초 1회만 set). 월 건수 쿼터 산정의 기준 — 재개/재시도는 갱신 안 함.
    # 이 컬럼이 non-null이면 그 달의 쿼터 슬롯을 이미 1건 소비했다는 뜻(중복 카운트 방지).
    ocr_started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    # admin(JWT role=admin) 업로드 → 페이지 캡·OCR 예산 모두 무제한. role은 DB에 없어 업로드 시점에 영속화.
    ocr_unlimited: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # "현재 규칙으로 is_scanned 평가를 끝냈나" 마커(scanned-pdf-ocr-spec §2.5). upload에서 무조건
    # 평가 시 true. 레거시/재사용은 노트 생성(intake) 시 POST /{id}/ensure가 false면 1회 재평가 → set.
    # PDF 파일 재오픈을 textbook당 평생 1회로 바운드(텍스트 PDF가 노트마다 재검사되는 것 방지).
    scan_evaluated: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # 하트비트 — running 잡이 페이지마다 갱신. 오래 안 갱신되면 프로세스 사망으로 판별(스위퍼 재개).
    ocr_updated_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc).replace(tzinfo=None))
    # soft delete — 서재 목록에서 숨기되 노트 연결·가이드/챕터/OCR 캐시·PDF 파일은 보존(복구 가능).
    # 목록/제안(list_textbooks·discover) 집계만 deleted_at IS NULL로 거른다. id 직접 접근(파일 서빙·
    # 챕터·가이드·피드백 컨텍스트·ensure)은 삭제돼도 허용 — 연결된 노트가 계속 동작해야 하므로.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
