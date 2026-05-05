"""기존 교재에 대해 TOC를 추출하거나 LLM으로 챕터를 감지하여 chapters 테이블에 저장하는 스크립트."""
import asyncio
import uuid
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import select
from app.core.database import async_session
from app.models.textbook import TextbookSource
from app.models.chapter import Chapter
from app.services.pdf_service import extract_toc
from app.services.chapter_service import detect_chapters


async def main():
    async with async_session() as db:
        result = await db.execute(select(TextbookSource))
        textbooks = result.scalars().all()

        for tb in textbooks:
            existing = await db.execute(
                select(Chapter).where(Chapter.textbook_id == tb.id).limit(1)
            )
            if existing.scalar_one_or_none():
                print(f"SKIP {tb.file_name} (already has chapters)")
                continue

            if not os.path.exists(tb.server_path):
                print(f"SKIP {tb.file_name} (file not found: {tb.server_path})")
                continue

            # 1차: PDF TOC 시도
            toc_entries = extract_toc(tb.server_path)

            # 2차: TOC 없으면 LLM 감지
            if not toc_entries:
                print(f"  {tb.file_name}: no TOC, trying LLM detection...")
                toc_entries = await detect_chapters(tb.server_path)

            if not toc_entries:
                print(f"SKIP {tb.file_name} (no chapters detected)")
                continue

            for i, entry in enumerate(toc_entries):
                next_page = None
                for j in range(i + 1, len(toc_entries)):
                    if toc_entries[j]["level"] <= entry["level"]:
                        next_page = toc_entries[j]["page"] - 1
                        break
                chapter = Chapter(
                    id=str(uuid.uuid4()),
                    textbook_id=tb.id,
                    level=entry["level"],
                    title=entry["title"],
                    page_start=entry["page"],
                    page_end=next_page or tb.total_pages,
                )
                db.add(chapter)

            await db.commit()
            print(f"OK {tb.file_name}: {len(toc_entries)} chapters saved")

    print("Done.")


if __name__ == "__main__":
    asyncio.run(main())
