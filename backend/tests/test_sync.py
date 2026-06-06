"""sync 엔드포인트 테스트 — pull/push/충돌/blob 멱등/유저 격리.

cloud-data-sync-spec A-6.
"""
import hashlib
import io

import pytest
from httpx import AsyncClient

from tests.conftest import make_test_token, TEST_USER_ID


def _note(id_: str, updated_at: str, title: str = "노트", deleted: bool = False,
          drawing_hash: str | None = None) -> dict:
    return {
        "id": id_,
        "updated_at": updated_at,
        "deleted": deleted,
        "title": title,
        "language": "fr",
        "textbook_id": None,
        "textbook_name": None,
        "textbook_pages": 0,
        "last_page": 1,
        "pdf_open": False,
        "current_page_index": 0,
        "drawing_hash": drawing_hash,
        "created_at": "2026-05-30T10:00:00Z",
    }


def _empty_changes() -> dict:
    return {
        "sessions": [],
        "folders": [],
        "notes": [],
        "note_pages": [],
        "pdf_annotations": [],
        "feedbacks": [],
        "chat_messages": [],
    }


def _folder(id_: str, updated_at: str, name: str = "라틴어",
            sort_order: int = 0, deleted: bool = False) -> dict:
    return {
        "id": id_,
        "updated_at": updated_at,
        "deleted": deleted,
        "name": name,
        "sort_order": sort_order,
        "created_at": "2026-06-06T01:00:00Z",
    }


def _session(id_: str, updated_at: str, title: str = "이 챕터에서 제일 중요한 게 뭐야?",
             kind: str = "chapter_guide", deleted: bool = False) -> dict:
    return {
        "id": id_,
        "updated_at": updated_at,
        "deleted": deleted,
        "kind": kind,
        "title": title,
        "note_id": None,
        "textbook_id": "tb-9",
        "anchor_page": 42,
        "chapter_title": "3장 동사 변화",
        "source_feedback_id": None,
        "created_at": "2026-06-06T01:00:00Z",
    }


def _chat(id_: str, updated_at: str, session_id: str, feedback_id: str | None = None,
          content: str = "안녕", role: str = "user", deleted: bool = False) -> dict:
    return {
        "id": id_,
        "updated_at": updated_at,
        "deleted": deleted,
        "session_id": session_id,
        "feedback_id": feedback_id,
        "role": role,
        "content": content,
        "server_message_id": None,
        "user_rating": None,
        "created_at": "2026-06-06T01:00:00Z",
    }


@pytest.mark.asyncio
async def test_pull_empty(client: AsyncClient, auth_header: dict):
    res = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    assert res.status_code == 200
    body = res.json()
    assert body["changes"] == _empty_changes()
    assert body["has_more"] is False
    assert "cursor" in body


@pytest.mark.asyncio
async def test_push_then_pull_roundtrip(client: AsyncClient, auth_header: dict):
    note = _note("note-1", "2026-06-01T09:00:00Z", title="라운드트립")
    push = await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "notes": [note]}},
    )
    assert push.status_code == 200
    results = push.json()["results"]
    assert len(results) == 1
    assert results[0]["status"] == "applied"
    assert results[0]["entity"] == "note"

    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    notes = pull.json()["changes"]["notes"]
    assert len(notes) == 1
    assert notes[0]["id"] == "note-1"
    assert notes[0]["title"] == "라운드트립"
    assert notes[0]["deleted"] is False


@pytest.mark.asyncio
async def test_push_lww_conflict(client: AsyncClient, auth_header: dict):
    # 서버에 최신 버전 적용
    newer = _note("note-2", "2026-06-01T10:00:00Z", title="최신")
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(), "notes": [newer]}})

    # 더 오래된 버전 push → conflict
    older = _note("note-2", "2026-06-01T08:00:00Z", title="구버전")
    res = await client.post("/api/sync/push", headers=auth_header,
                            json={"changes": {**_empty_changes(), "notes": [older]}})
    result = res.json()["results"][0]
    assert result["status"] == "conflict"

    # 서버본은 그대로 "최신"
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    assert pull.json()["changes"]["notes"][0]["title"] == "최신"


@pytest.mark.asyncio
async def test_pull_since_cursor(client: AsyncClient, auth_header: dict):
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(),
                                        "notes": [_note("n-old", "2026-06-01T08:00:00Z")]}})
    first = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    cursor = first.json()["cursor"]

    # cursor 이후 새 변경 push
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(),
                                        "notes": [_note("n-new", "2026-06-01T09:00:00Z")]}})
    second = await client.post("/api/sync/pull", headers=auth_header, json={"since": cursor})
    ids = [n["id"] for n in second.json()["changes"]["notes"]]
    assert "n-new" in ids


@pytest.mark.asyncio
async def test_soft_delete_tombstone_syncs(client: AsyncClient, auth_header: dict):
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(),
                                        "notes": [_note("n-del", "2026-06-01T08:00:00Z")]}})
    tomb = _note("n-del", "2026-06-01T09:00:00Z", deleted=True)
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(), "notes": [tomb]}})
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    note = pull.json()["changes"]["notes"][0]
    assert note["deleted"] is True


@pytest.mark.asyncio
async def test_blob_upload_idempotent_and_download(client: AsyncClient, auth_header: dict):
    data = b"hello drawing blob"
    h = hashlib.sha256(data).hexdigest()
    res1 = await client.post(
        "/api/sync/blob", headers=auth_header,
        data={"hash": h}, files={"file": ("blob.bin", io.BytesIO(data), "application/octet-stream")},
    )
    assert res1.status_code == 200
    assert res1.json()["stored"] is True

    # 멱등: 동일 hash 재업로드
    res2 = await client.post(
        "/api/sync/blob", headers=auth_header,
        data={"hash": h}, files={"file": ("blob.bin", io.BytesIO(data), "application/octet-stream")},
    )
    assert res2.status_code == 200

    # 다운로드
    dl = await client.get(f"/api/sync/blob/{h}", headers=auth_header)
    assert dl.status_code == 200
    assert dl.content == data


@pytest.mark.asyncio
async def test_blob_hash_mismatch_rejected(client: AsyncClient, auth_header: dict):
    data = b"actual content"
    wrong = hashlib.sha256(b"different").hexdigest()
    res = await client.post(
        "/api/sync/blob", headers=auth_header,
        data={"hash": wrong}, files={"file": ("blob.bin", io.BytesIO(data), "application/octet-stream")},
    )
    assert res.status_code == 400


@pytest.mark.asyncio
async def test_push_missing_blob(client: AsyncClient, auth_header: dict):
    # 서버에 없는 drawing_hash 참조 → missing_blob
    note = _note("n-blob", "2026-06-01T09:00:00Z", drawing_hash="deadbeef" * 8)
    res = await client.post("/api/sync/push", headers=auth_header,
                            json={"changes": {**_empty_changes(), "notes": [note]}})
    body = res.json()
    assert body["results"][0]["status"] == "missing_blob"
    assert "deadbeef" * 8 in body["missing_blobs"]

    # 서버에는 적용되지 않았어야 함
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    assert pull.json()["changes"]["notes"] == []


@pytest.mark.asyncio
async def test_cross_user_isolation(client: AsyncClient, db_session):
    """A 유저가 push한 노트를 B 유저가 pull로 볼 수 없어야 한다."""
    from app.models.user import User

    user_a = TEST_USER_ID
    user_b = "test-user-00000000-0000-0000-0000-0000000000ff"
    # B 유저 생성
    db_session.add(User(id=user_b, email="userb@scatchlm.com"))
    await db_session.commit()

    token_a = make_test_token(user_a)
    token_b = make_test_token(user_b)

    await client.post("/api/sync/push", headers={"Authorization": f"Bearer {token_a}"},
                      json={"changes": {**_empty_changes(),
                                        "notes": [_note("a-note", "2026-06-01T09:00:00Z")]}})

    pull_b = await client.post("/api/sync/pull", headers={"Authorization": f"Bearer {token_b}"},
                               json={"since": None})
    assert pull_b.json()["changes"]["notes"] == []

    # B가 A의 id로 push 시도 → conflict(타 유저 소유 거부)
    conflict = await client.post("/api/sync/push", headers={"Authorization": f"Bearer {token_b}"},
                                 json={"changes": {**_empty_changes(),
                                                   "notes": [_note("a-note", "2026-06-01T11:00:00Z", title="탈취")]}})
    assert conflict.json()["results"][0]["status"] == "conflict"


@pytest.mark.asyncio
async def test_session_push_pull_roundtrip(client: AsyncClient, auth_header: dict):
    """chat_session 엔티티 push→pull 라운드트립 (chapter-chat-drawer-spec §3.2-a)."""
    session = _session("sess-1", "2026-06-06T02:00:00Z")
    push = await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "sessions": [session]}},
    )
    assert push.status_code == 200
    result = push.json()["results"][0]
    assert result["status"] == "applied"
    assert result["entity"] == "chat_session"

    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    sessions = pull.json()["changes"]["sessions"]
    assert len(sessions) == 1
    assert sessions[0]["id"] == "sess-1"
    assert sessions[0]["kind"] == "chapter_guide"
    assert sessions[0]["anchor_page"] == 42
    assert sessions[0]["chapter_title"] == "3장 동사 변화"


@pytest.mark.asyncio
async def test_chat_message_session_id_preserved(client: AsyncClient, auth_header: dict):
    """chat_message가 session_id를 보존하고 feedback_id는 null 가능해야 한다(§3.2-a / R3)."""
    session = _session("sess-2", "2026-06-06T02:00:00Z")
    msg = _chat("msg-1", "2026-06-06T02:00:01Z", session_id="sess-2", feedback_id=None)
    res = await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "sessions": [session], "chat_messages": [msg]}},
    )
    assert res.status_code == 200
    statuses = {r["entity"]: r["status"] for r in res.json()["results"]}
    assert statuses["chat_session"] == "applied"
    assert statuses["chat_message"] == "applied"

    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    msgs = pull.json()["changes"]["chat_messages"]
    assert len(msgs) == 1
    assert msgs[0]["session_id"] == "sess-2"
    assert msgs[0]["feedback_id"] is None


@pytest.mark.asyncio
async def test_folder_push_pull_roundtrip(client: AsyncClient, auth_header: dict):
    """folder 엔티티 push→pull 라운드트립 (note-folders-spec §3.2)."""
    folder = _folder("folder-1", "2026-06-06T02:00:00Z", name="그리스어", sort_order=2)
    push = await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "folders": [folder]}},
    )
    assert push.status_code == 200
    result = push.json()["results"][0]
    assert result["status"] == "applied"
    assert result["entity"] == "folder"

    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    folders = pull.json()["changes"]["folders"]
    assert len(folders) == 1
    assert folders[0]["id"] == "folder-1"
    assert folders[0]["name"] == "그리스어"
    assert folders[0]["sort_order"] == 2


@pytest.mark.asyncio
async def test_note_folder_id_preserved(client: AsyncClient, auth_header: dict):
    """note.folder_id가 push→pull로 보존되어야 한다 (note-folders-spec §3.2-a)."""
    folder = _folder("folder-2", "2026-06-06T02:00:00Z")
    note = {**_note("n-fld", "2026-06-06T02:00:01Z"), "folder_id": "folder-2"}
    await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "folders": [folder], "notes": [note]}},
    )
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    pulled = pull.json()["changes"]["notes"][0]
    assert pulled["folder_id"] == "folder-2"


@pytest.mark.asyncio
async def test_note_template_preserved(client: AsyncClient, auth_header: dict):
    """note.template이 push→pull로 보존되어야 한다 (canvas-template)."""
    note = {**_note("n-tpl", "2026-06-06T03:00:00Z"), "template": "staff"}
    await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "notes": [note]}},
    )
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    pulled = pull.json()["changes"]["notes"][0]
    assert pulled["template"] == "staff"


@pytest.mark.asyncio
async def test_note_template_defaults_blank_when_omitted(client: AsyncClient, auth_header: dict):
    """구버전 클라(template 미전송)는 서버 기본값 'blank'로 채워져 pull된다."""
    note = _note("n-notpl", "2026-06-06T03:00:01Z")  # template 키 없음
    await client.post(
        "/api/sync/push", headers=auth_header,
        json={"changes": {**_empty_changes(), "notes": [note]}},
    )
    pull = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    pulled = pull.json()["changes"]["notes"][0]
    assert pulled["template"] == "blank"


@pytest.mark.asyncio
async def test_purge_hard_deletes_note(client: AsyncClient, auth_header: dict):
    """purge는 서버 행을 하드 삭제해 full-pull에 부활하지 않아야 한다 (휴지통 영구삭제)."""
    note = _note("n-purge", "2026-06-01T09:00:00Z", deleted=True)
    await client.post("/api/sync/push", headers=auth_header,
                      json={"changes": {**_empty_changes(), "notes": [note]}})
    # tombstone이 pull로 돌아옴(아직 살아있음)
    pull1 = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    assert any(n["id"] == "n-purge" for n in pull1.json()["changes"]["notes"])

    # purge → 하드 삭제
    res = await client.post("/api/sync/purge", headers=auth_header,
                            json={"note_ids": ["n-purge"]})
    assert res.status_code == 200
    assert res.json()["purged"] == ["n-purge"]

    # full-pull에 더 이상 안 나옴(행 자체가 사라짐)
    pull2 = await client.post("/api/sync/pull", headers=auth_header, json={"since": None})
    assert all(n["id"] != "n-purge" for n in pull2.json()["changes"]["notes"])


@pytest.mark.asyncio
async def test_purge_is_idempotent_and_scoped(client: AsyncClient, auth_header: dict):
    """없는 id/이미 purge된 id는 no-op(멱등). 빈 결과."""
    res = await client.post("/api/sync/purge", headers=auth_header,
                            json={"note_ids": ["does-not-exist"]})
    assert res.status_code == 200
    assert res.json()["purged"] == []


@pytest.mark.asyncio
async def test_unauthenticated_rejected(client: AsyncClient):
    res = await client.post("/api/sync/pull", json={"since": None})
    assert res.status_code == 401
