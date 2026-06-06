"""레거시 교재의 is_scanned 일회성 백필 (docs/scanned-pdf-ocr-spec.md §2.5).

배경: is_scanned는 원래 ENABLE_OCR로 게이팅돼 업로드 시점에 계산됐다. 그래서 OCR을 켜기 전
또는 구버전 임계값 로직으로 올라간 스캔본은 is_scanned=false로 굳어, 재사용/노트첨부로 열어도
OCR 제안이 뜨지 않는다. 현재 모델은 is_scanned를 파일 고유 속성(텍스트 레이어 유무)으로 보고
upload 시 무조건 평가한다. 이 스크립트는 그 invariant를 기존 레코드에 일회성으로 적용한다.

동작: is_scanned=false 레코드를 has_no_text_layer로 재평가 → 텍스트 레이어가 비었으면
is_scanned=true로 갱신하고, ENABLE_OCR이면 ocr_status="available"로 OCR 제안을 띄운다.
ocr_cap/무제한 같은 tier 의존 예산은 시작 시점(start_ocr)에 결정하므로 여기서 안 건드린다.

실행(운영):
  docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T app \
    python scripts/backfill_scanned.py
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import select

from app.core.config import settings
from app.core.database import async_session
from app.models.textbook import TextbookSource
from app.services.pdf_service import has_no_text_layer


async def main(dry_run: bool = False):
    flipped = checked = 0
    async with async_session() as db:
        rows = (await db.execute(
            select(TextbookSource).where(TextbookSource.is_scanned.is_(False))
        )).scalars().all()
        print(f"candidates (is_scanned=false): {len(rows)}  ENABLE_OCR={settings.ENABLE_OCR}")

        for tb in rows:
            checked += 1
            try:
                empty = has_no_text_layer(tb.server_path, tb.total_pages)
            except Exception as e:
                print(f"  SKIP {tb.file_name} (open failed: {e})")
                continue
            if not empty:
                continue  # 진짜 텍스트 PDF — 그대로 둠
            flipped += 1
            print(f"  SCANNED {tb.file_name} (id={tb.id}) → is_scanned=true"
                  + ("" if dry_run else f", ocr_status={'available' if settings.ENABLE_OCR else None}"))
            if not dry_run:
                tb.is_scanned = True
                if settings.ENABLE_OCR and tb.ocr_status is None:
                    tb.ocr_status = "available"
        if not dry_run:
            await db.commit()
    print(f"done: checked={checked} flipped_to_scanned={flipped} dry_run={dry_run}")


if __name__ == "__main__":
    asyncio.run(main(dry_run="--dry-run" in sys.argv))
