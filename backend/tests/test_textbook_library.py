"""서재(교재 목록) — 검색·페이지네이션·soft delete/복구 회귀 테스트."""
import io

import pytest
from httpx import AsyncClient


def make_pdf(text: str, pages: int = 1) -> bytes:
    """내용이 다른 PDF를 만든다(content_hash가 달라 dedup을 피함)."""
    import fitz

    doc = fitz.open()
    for i in range(pages):
        page = doc.new_page()
        page.insert_text((72, 72), f"{text} page {i + 1}")
    data = doc.tobytes()
    doc.close()
    return data


async def _upload(client: AsyncClient, auth_header: dict, name: str, text: str) -> str:
    res = await client.post(
        "/api/pdf/upload",
        headers=auth_header,
        files={"file": (name, io.BytesIO(make_pdf(text)), "application/pdf")},
    )
    assert res.status_code == 200, res.text
    return res.json()["id"]


@pytest.mark.asyncio
async def test_list_envelope_and_pagination(client: AsyncClient, auth_header: dict):
    ids = []
    for i in range(3):
        ids.append(await _upload(client, auth_header, f"book{i}.pdf", f"unique-content-{i}"))

    # 봉투 형태 + 페이지네이션(limit=2 → has_more=true)
    res = await client.get("/api/pdf/textbooks", headers=auth_header, params={"limit": 2, "offset": 0})
    assert res.status_code == 200
    body = res.json()
    assert set(body.keys()) >= {"items", "total", "has_more"}
    assert body["total"] >= 3
    assert len(body["items"]) == 2
    assert body["has_more"] is True

    # 다음 페이지
    res2 = await client.get("/api/pdf/textbooks", headers=auth_header, params={"limit": 2, "offset": 2})
    assert res2.status_code == 200
    page1_ids = {it["id"] for it in body["items"]}
    page2_ids = {it["id"] for it in res2.json()["items"]}
    assert page1_ids.isdisjoint(page2_ids)  # 페이지 간 중복 없음


@pytest.mark.asyncio
async def test_search_by_filename(client: AsyncClient, auth_header: dict):
    await _upload(client, auth_header, "japanese_grammar.pdf", "search-a")
    await _upload(client, auth_header, "physics_notes.pdf", "search-b")

    res = await client.get("/api/pdf/textbooks", headers=auth_header, params={"q": "japanese"})
    assert res.status_code == 200
    names = [it["fileName"] for it in res.json()["items"]]
    assert any("japanese" in n.lower() for n in names)
    assert all("physics" not in n.lower() for n in names)


@pytest.mark.asyncio
async def test_soft_delete_hides_and_restore(client: AsyncClient, auth_header: dict):
    tid = await _upload(client, auth_header, "to_delete.pdf", "delete-flow")

    # 삭제 → 기본 목록에서 사라지고, deleted=true 목록에 나타난다.
    res = await client.delete(f"/api/pdf/{tid}", headers=auth_header)
    assert res.status_code == 200
    assert res.json() == {"id": tid, "deleted": True}

    active = await client.get("/api/pdf/textbooks", headers=auth_header)
    assert tid not in {it["id"] for it in active.json()["items"]}

    deleted = await client.get("/api/pdf/textbooks", headers=auth_header, params={"deleted": "true"})
    assert tid in {it["id"] for it in deleted.json()["items"]}

    # 삭제돼도 id 직접 접근(파일 서빙)은 유지 — 연결 노트가 계속 동작해야 함.
    file_res = await client.get(f"/api/pdf/{tid}/file", headers=auth_header)
    assert file_res.status_code == 200

    # 복구 → 다시 기본 목록에.
    restore = await client.post(f"/api/pdf/{tid}/restore", headers=auth_header)
    assert restore.status_code == 200
    assert restore.json()["id"] == tid

    active2 = await client.get("/api/pdf/textbooks", headers=auth_header)
    assert tid in {it["id"] for it in active2.json()["items"]}


@pytest.mark.asyncio
async def test_delete_is_idempotent(client: AsyncClient, auth_header: dict):
    tid = await _upload(client, auth_header, "twice.pdf", "idempotent-flow")
    r1 = await client.delete(f"/api/pdf/{tid}", headers=auth_header)
    r2 = await client.delete(f"/api/pdf/{tid}", headers=auth_header)
    assert r1.status_code == 200 and r2.status_code == 200
    assert r2.json()["deleted"] is True


@pytest.mark.asyncio
async def test_reupload_deleted_resurrects(client: AsyncClient, auth_header: dict):
    """삭제된 교재를 같은 파일로 재업로드하면 복구된다(dedup 경로)."""
    pdf = make_pdf("resurrect-content")
    up = await client.post(
        "/api/pdf/upload", headers=auth_header,
        files={"file": ("res.pdf", io.BytesIO(pdf), "application/pdf")},
    )
    tid = up.json()["id"]
    await client.delete(f"/api/pdf/{tid}", headers=auth_header)

    # 동일 content → dedup으로 같은 id 재사용 + 복구
    up2 = await client.post(
        "/api/pdf/upload", headers=auth_header,
        files={"file": ("res.pdf", io.BytesIO(pdf), "application/pdf")},
    )
    assert up2.json()["id"] == tid

    active = await client.get("/api/pdf/textbooks", headers=auth_header)
    assert tid in {it["id"] for it in active.json()["items"]}
