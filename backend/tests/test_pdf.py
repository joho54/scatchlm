import io
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from urllib.parse import quote

import pytest
from httpx import AsyncClient

from app.services.pdf_service import extract_text


def make_test_pdf() -> bytes:
    """PyMuPDF로 간단한 테스트 PDF를 생성한다."""
    import fitz

    doc = fitz.open()
    for i in range(3):
        page = doc.new_page()
        page.insert_text((72, 72), f"Page {i + 1} content: hello world")
    data = doc.tobytes()
    doc.close()
    return data


@pytest.mark.asyncio
async def test_upload_pdf(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 200
    data = res.json()
    assert data["totalPages"] == 3
    assert data["fileName"] == "test.pdf"
    assert "id" in data


@pytest.mark.asyncio
async def test_upload_non_pdf(client: AsyncClient, auth_header: dict):
    res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.txt", io.BytesIO(b"hello"), "text/plain")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_upload_and_extract(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    res = await client.get(
        "/api/pdf/extract",
        headers=auth_header,
        params={"textbook_id": textbook_id, "page_start": 1, "page_end": 2},
    )
    assert res.status_code == 200
    assert "hello world" in res.json()["text"]


@pytest.mark.asyncio
async def test_extract_invalid_page_range(client: AsyncClient, auth_header: dict):
    pdf_bytes = make_test_pdf()
    upload_res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": ("test.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    textbook_id = upload_res.json()["id"]

    res = await client.get(
        "/api/pdf/extract",
        headers=auth_header,
        params={"textbook_id": textbook_id, "page_start": 1, "page_end": 10},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_upload_requires_auth(client: AsyncClient):
    res = await client.post(
        "/api/pdf/upload",
        files={"file": ("test.pdf", io.BytesIO(b"%PDF"), "application/pdf")},
        data={"note_id": "note-1"},
    )
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_serve_pdf_file_non_ascii_filename_streaming(
    client: AsyncClient, auth_header: dict
):
    """회귀: 비-ASCII 파일명 + S3(StreamingResponse) 경로에서 /file이 500이 아니라 200을 반환.

    Content-Disposition 헤더는 latin-1로만 인코딩되므로 한글/아랍어 파일명을 날것으로
    실으면 UnicodeEncodeError(500)가 났다. RFC 5987(filename*=UTF-8'') 인코딩으로 수정.
    """
    pdf_bytes = make_test_pdf()
    filename = "2026 수능완성 아랍어 I.pdf"
    upload = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": (filename, io.BytesIO(pdf_bytes), "application/pdf")},
        data={"note_id": "note-1"},
    )
    assert upload.status_code == 200
    textbook_id = upload.json()["id"]

    # 운영(S3) 환경을 흉내: 로컬 파일이 없어 StreamingResponse 분기를 타게 강제
    def fake_stream(key: str):
        yield pdf_bytes

    with patch("app.routers.pdf.storage.local_path", return_value=None), \
         patch("app.routers.pdf.os.path.exists", return_value=False), \
         patch("app.routers.pdf.storage.stream", side_effect=fake_stream):
        res = await client.get(f"/api/pdf/{textbook_id}/file", headers=auth_header)

    assert res.status_code == 200
    assert res.headers["content-type"] == "application/pdf"
    # 파일명이 RFC 5987 방식으로 인코딩돼 헤더에 안전하게 실려야 함
    assert "filename*=UTF-8''" in res.headers["content-disposition"]
    assert quote(filename) in res.headers["content-disposition"]


MOCK_PAGE_GUIDE = {"topic": "테스트 주제", "content": "테스트 가이드 본문"}
# 가이드/챕터 생성 함수는 이제 (data, usage) 튜플을 반환한다. usage는 llm_usage 적재용.
MOCK_USAGE = SimpleNamespace(input_tokens=100, output_tokens=200)


async def _upload_test_pdf(client: AsyncClient, auth_header: dict) -> str:
    # 백그라운드 인덱싱은 테스트 트랜잭션 밖에서 실행돼 FK 위반을 일으키므로 무력화
    with patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_detect_chapters", new_callable=AsyncMock):
        res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("g.pdf", io.BytesIO(make_test_pdf()), "application/pdf")},
            data={"note_id": "note-g"},
        )
    assert res.status_code == 200
    return res.json()["id"]


@pytest.mark.asyncio
async def test_page_guide_returns_feedback_id_cache_miss_then_hit(
    client: AsyncClient, auth_header: dict
):
    """페이지 가이드 응답은 평가 대상 AIResponse id를 반환하고, 캐시 히트 시에도 동일 id."""
    textbook_id = await _upload_test_pdf(client, auth_header)

    with patch(
        "app.routers.pdf.generate_page_guide",
        new_callable=AsyncMock,
        return_value=(MOCK_PAGE_GUIDE, MOCK_USAGE),
    ):
        miss = await client.get(
            f"/api/pdf/{textbook_id}/guide",
            headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
    assert miss.status_code == 200
    miss_data = miss.json()
    assert miss_data["cached"] is False
    miss_id = miss_data.get("feedback_id")
    assert isinstance(miss_id, str) and len(miss_id) > 0

    # 두 번째 호출은 캐시 히트 — generate_page_guide 호출 없이도 동일 feedback_id 반환
    hit = await client.get(
        f"/api/pdf/{textbook_id}/guide",
        headers=auth_header,
        params={"page": 1, "response_language": "Korean"},
    )
    assert hit.status_code == 200
    hit_data = hit.json()
    assert hit_data["cached"] is True
    assert hit_data["feedback_id"] == miss_id

    # 반환된 id로 평가 가능해야 함
    rate = await client.post(
        f"/api/feedback/{miss_id}/rate",
        headers=auth_header,
        json={"rating": 1, "reason_tags": []},
    )
    assert rate.status_code == 204


@pytest.mark.asyncio
async def test_page_guide_cache_keyed_by_response_language(
    client: AsyncClient, auth_header: dict
):
    """Track H: 캐시 키에 response_language 포함 — 언어 전환 시 stale 가이드 대신 신규 생성."""
    textbook_id = await _upload_test_pdf(client, auth_header)

    with patch(
        "app.routers.pdf.generate_page_guide",
        new_callable=AsyncMock,
        return_value=(MOCK_PAGE_GUIDE, MOCK_USAGE),
    ) as gen:
        # Korean 최초 → 생성(miss)
        ko_miss = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
        # Korean 재요청 → 캐시 히트(생성 안 함)
        ko_hit = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "Korean"},
        )
        # English 요청 → 같은 page지만 언어가 달라 신규 생성(stale Korean 아님)
        en_miss = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "English"},
        )
        # English 재요청 → 캐시 히트
        en_hit = await client.get(
            f"/api/pdf/{textbook_id}/guide", headers=auth_header,
            params={"page": 1, "response_language": "English"},
        )

    assert ko_miss.json()["cached"] is False
    assert ko_hit.json()["cached"] is True
    assert en_miss.json()["cached"] is False   # 언어 차원이 작동 → 신규 생성
    assert en_hit.json()["cached"] is True
    # 생성은 Korean 1회 + English 1회 = 2회 (언어별 캐시)
    assert gen.await_count == 2


MOCK_CHAPTER_GUIDE = {
    "topic": "ch topic",
    "key_concepts": ["a"],
    "study_order": ["1. read"],
    "common_mistakes": ["x"],
    "summary": "요약",
}


@pytest.mark.asyncio
async def test_chapter_guide_returns_feedback_id_cache_miss_then_hit(
    client: AsyncClient, auth_header: dict, engine
):
    """챕터 가이드도 동일 — feedback_id 반환, 캐시 히트 시 동일 id, 평가 가능."""
    import uuid
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
    from app.models.chapter import Chapter

    textbook_id = await _upload_test_pdf(client, auth_header)
    chapter_id = str(uuid.uuid4())
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with session_factory() as db:
        db.add(Chapter(
            id=chapter_id,
            textbook_id=textbook_id,
            level=1,
            title="Ch 1",
            page_start=1,
            page_end=3,
        ))
        await db.commit()

    with patch(
        "app.routers.pdf.generate_chapter_guide",
        new_callable=AsyncMock,
        return_value=(MOCK_CHAPTER_GUIDE, MOCK_USAGE),
    ):
        miss = await client.get(
            f"/api/pdf/{textbook_id}/chapter-guide",
            headers=auth_header,
            params={"chapter_id": chapter_id, "response_language": "Korean"},
        )
    assert miss.status_code == 200
    miss_data = miss.json()
    assert miss_data["cached"] is False
    miss_id = miss_data.get("feedback_id")
    assert isinstance(miss_id, str) and len(miss_id) > 0

    hit = await client.get(
        f"/api/pdf/{textbook_id}/chapter-guide",
        headers=auth_header,
        params={"chapter_id": chapter_id, "response_language": "Korean"},
    )
    assert hit.status_code == 200
    hit_data = hit.json()
    assert hit_data["cached"] is True
    assert hit_data["feedback_id"] == miss_id

    rate = await client.post(
        f"/api/feedback/{miss_id}/rate",
        headers=auth_header,
        json={"rating": -1, "reason_tags": ["tone_off"]},
    )
    assert rate.status_code == 204


# --- 스캔본 OCR: 자동시작 제거 + 명시적 시작 (scanned-pdf-ocr-spec §2.1, §3.2-d) ---

def make_blank_pdf(pages: int = 4) -> bytes:
    """텍스트 레이어 없는(스캔본 모사) 빈 페이지 PDF — has_no_text_layer → True."""
    import fitz

    doc = fitz.open()
    for _ in range(pages):
        doc.new_page()
    data = doc.tobytes()
    doc.close()
    return data


async def _upload(client: AsyncClient, header: dict, pdf_bytes: bytes) -> dict:
    res = await client.post(
        "/api/pdf/upload",
        headers=header,
        files={"file": ("scan.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
    )
    assert res.status_code == 200
    return res.json()


@pytest.mark.asyncio
async def test_scanned_upload_does_not_autostart_ocr(client: AsyncClient, auth_header: dict):
    """스캔본 업로드 → is_scanned, ocr_status='available'(시작 대기). _background_ocr 자동등록 안 함."""
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_ocr", new_callable=AsyncMock) as ocr_job:
        data = await _upload(client, auth_header, make_blank_pdf())
    assert data["is_scanned"] is True
    assert data["ocr_status"] == "available"
    ocr_job.assert_not_called()  # 자동 시작 없음


@pytest.mark.asyncio
async def test_ocr_start_transitions_available_to_pending(client: AsyncClient, auth_header: dict):
    """명시적 start → available→pending, 백그라운드 잡 등록."""
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_ocr", new_callable=AsyncMock) as ocr_job:
        data = await _upload(client, auth_header, make_blank_pdf())
        tid = data["id"]
        res = await client.post(f"/api/pdf/{tid}/ocr/start", headers=auth_header)
        assert res.status_code == 200
        assert res.json()["ocr_status"] == "pending"
        ocr_job.assert_called_once()  # 명시적 시작 시에만 등록


@pytest.mark.asyncio
async def test_ocr_start_on_text_pdf_returns_400(client: AsyncClient, auth_header: dict):
    """텍스트 레이어 있는 PDF(is_scanned=false)에 start → 400."""
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_detect_chapters", new_callable=AsyncMock):
        data = await _upload(client, auth_header, make_test_pdf())
        assert data["is_scanned"] is False
        res = await client.post(f"/api/pdf/{data['id']}/ocr/start", headers=auth_header)
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_ensure_reevaluates_legacy_once(client: AsyncClient, auth_header: dict, db_session):
    """intake(ensure, A): 레거시 stale(scan_evaluated=false, is_scanned=false)를 1회 재평가해
    is_scanned 복구 + available 파생. 마커로 파일 재오픈은 평생 1회(2번째 ensure는 안 엶)."""
    from sqlalchemy import update
    from app.models.textbook import TextbookSource

    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock):
        up = await _upload(client, auth_header, make_blank_pdf())
    tid = up["id"]
    # 게이팅 시절 stale 모사: is_scanned=false로 굳고 아직 재평가 안 됨
    await db_session.execute(
        update(TextbookSource).where(TextbookSource.id == tid)
        .values(is_scanned=False, scan_evaluated=False, ocr_status=None)
    )
    await db_session.commit()

    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf.has_no_text_layer", return_value=True) as detect:
        first = await client.post(f"/api/pdf/{tid}/ensure", headers=auth_header)
        second = await client.post(f"/api/pdf/{tid}/ensure", headers=auth_header)
    assert first.status_code == 200
    assert first.json()["is_scanned"] is True        # 재평가로 복구
    assert first.json()["ocr_status"] == "available"  # 파생
    assert detect.call_count == 1                      # 마커 → 파일 재오픈 평생 1회


@pytest.mark.asyncio
async def test_scanned_status_no_per_tier_cap(client: AsyncClient, auth_header: dict):
    """per-tier 페이지 캡 폐지: status는 cap_limit=null, capped=false, ocr_pages_total=min(total,천장)."""
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock):
        up = await _upload(client, auth_header, make_blank_pdf(pages=60))
        st = await client.get(f"/api/pdf/{up['id']}/status", headers=auth_header)
    assert st.status_code == 200
    body = st.json()
    assert body["cap_limit"] is None       # deprecated — 항상 null
    assert body["capped"] is False         # deprecated — 항상 false
    assert body["ocr_pages_total"] == 60   # min(60, OCR_MAX_PAGES_PER_FILE=200) = 60(=total)


@pytest.mark.asyncio
async def test_scanned_over_page_limit_rejected(client: AsyncClient, auth_header: dict):
    """천장(OCR_MAX_PAGES_PER_FILE) 초과 스캔본 업로드는 422로 거부된다(원자 처리 원칙)."""
    with patch("app.routers.pdf.settings.OCR_MAX_PAGES_PER_FILE", 5), \
         patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock):
        res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("scan.pdf", io.BytesIO(make_blank_pdf(pages=6)), "application/pdf")},
        )
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert detail["code"] == "scanned_page_limit_exceeded"
    assert detail["limit"] == 5 and detail["pages"] == 6


@pytest.mark.asyncio
async def test_text_pdf_over_page_limit_allowed(client: AsyncClient, auth_header: dict):
    """텍스트 레이어 PDF는 OCR 불요 → 페이지 천장 무관(거부 안 함)."""
    import fitz
    doc = fitz.open()
    for i in range(6):
        p = doc.new_page()
        p.insert_text((72, 72), f"page {i} has a real text layer")
    pdf_bytes = doc.tobytes()
    doc.close()
    with patch("app.routers.pdf.settings.OCR_MAX_PAGES_PER_FILE", 5), \
         patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_detect_chapters", new_callable=AsyncMock):
        res = await client.post(
            "/api/pdf/upload",
            headers=auth_header,
            files={"file": ("text.pdf", io.BytesIO(pdf_bytes), "application/pdf")},
        )
    assert res.status_code == 200
    assert res.json()["is_scanned"] is False


@pytest.mark.asyncio
async def test_ocr_monthly_quota_gate_and_resume(client: AsyncClient, auth_header: dict, db_session):
    """월 건수 한도 초과 시 start_ocr이 429. 이미 시작한 책의 재개는 재카운트 없이 통과."""
    from sqlalchemy import update
    from app.models.textbook import TextbookSource
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.core.quota.settings.OCR_MONTHLY_FILES_FREE", 1), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_ocr", new_callable=AsyncMock):
        a = await _upload(client, auth_header, make_blank_pdf(pages=4))
        b = await _upload(client, auth_header, make_blank_pdf(pages=5))  # 다른 페이지수 → 다른 hash(중복 회피)

        # 1건째 시작 → OK, 그 달의 슬롯 1 소비(ocr_started_at set)
        r1 = await client.post(f"/api/pdf/{a['id']}/ocr/start", headers=auth_header)
        assert r1.status_code == 200

        # 2건째(다른 책) 시작 → 월 한도(1) 초과 → 429 ocr_quota_exceeded
        r2 = await client.post(f"/api/pdf/{b['id']}/ocr/start", headers=auth_header)
        assert r2.status_code == 429
        assert r2.json()["detail"]["code"] == "ocr_quota_exceeded"

        # a를 paused로 강등(백스톱/스위퍼 시나리오) 후 재시작 → 이미 슬롯 소비 → 재카운트 없이 200
        await db_session.execute(
            update(TextbookSource).where(TextbookSource.id == a["id"]).values(ocr_status="paused")
        )
        await db_session.commit()
        r3 = await client.post(f"/api/pdf/{a['id']}/ocr/start", headers=auth_header)
        assert r3.status_code == 200


@pytest.mark.asyncio
async def test_scanned_eval_unconditional_status_derives_available(client: AsyncClient, auth_header: dict):
    """is_scanned는 ENABLE_OCR과 무관하게 upload 때 평가(파일 고유 속성). ocr_status='available'
    제안은 ENABLE_OCR이 켜진 뒤 status 첫 읽기에서 파생 — 재사용/노트첨부로 열어도 OCR이 뜬다."""
    # 1) OCR off로 업로드 → 스캔본으로 평가되지만 제안은 아직 없음
    with patch("app.routers.pdf.settings.ENABLE_OCR", False), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_detect_chapters", new_callable=AsyncMock):
        up = await _upload(client, auth_header, make_blank_pdf())
    assert up["is_scanned"] is True     # ENABLE_OCR 꺼져도 스캔본 평가됨(파일 속성)
    assert up["ocr_status"] is None      # 제안은 ENABLE_OCR off라 아직 없음
    # 2) ENABLE_OCR on에서 status 첫 읽기 → ocr_status null→available 파생(PDF 재오픈 없음)
    with patch("app.routers.pdf.settings.ENABLE_OCR", True):
        st = await client.get(f"/api/pdf/{up['id']}/status", headers=auth_header)
    assert st.status_code == 200
    assert st.json()["ocr_status"] == "available"


@pytest.mark.asyncio
async def test_admin_scanned_upload_is_unlimited(client: AsyncClient, admin_header: dict):
    """admin(role=admin) 스캔본 → status.cap_limit=null, ocr_pages_total=풀북."""
    with patch("app.routers.pdf.settings.ENABLE_OCR", True), \
         patch("app.routers.pdf._background_index", new_callable=AsyncMock), \
         patch("app.routers.pdf._background_ocr", new_callable=AsyncMock):
        data = await _upload(client, admin_header, make_blank_pdf(pages=8))
        tid = data["id"]
        status = await client.get(f"/api/pdf/{tid}/status", headers=admin_header)
    assert status.status_code == 200
    body = status.json()
    assert body["is_scanned"] is True
    assert body["cap_limit"] is None          # 무제한
    assert body["ocr_pages_total"] == body["total_pages"]  # 풀북
