"""Discover 단위 테스트 — docs/discover-feature-spec.md A-5 회귀 가드.

LLM/HTTP는 호출하지 않는다. 파싱(코드펜스/잡텍스트 방어), 계약 검증(enum·http url),
URL 재검증(httpx mock으로 PDF content-type/상태코드 분기)을 고정한다.
"""
import httpx
import pytest

from app.services import discover_service as ds


# ── _parse_recommendations: 방어적 JSON 추출 ───────────────────────────────

def test_parse_plain_json():
    text = '{"recommendations": [], "note": "x"}'
    assert ds._parse_recommendations(text) == {"recommendations": [], "note": "x"}


def test_parse_code_fence():
    text = '```json\n{"recommendations": [], "note": ""}\n```'
    assert ds._parse_recommendations(text)["note"] == ""


def test_parse_prose_around_json():
    text = 'Here is the result:\n{"recommendations": [], "note": "ok"}\nDone.'
    assert ds._parse_recommendations(text)["note"] == "ok"


def test_parse_nested_braces_in_string():
    text = '{"recommendations": [], "note": "a {b} c"}'
    assert ds._parse_recommendations(text)["note"] == "a {b} c"


def test_parse_garbage_returns_empty():
    assert ds._parse_recommendations("no json here") == {"recommendations": [], "note": ""}
    assert ds._parse_recommendations("") == {"recommendations": [], "note": ""}


# ── _sanitize: 계약 검증 ──────────────────────────────────────────────────

def _rec(**kw):
    base = {
        "title": "T", "url": "https://x.org/a", "format": "PDF",
        "level": "학부기초", "why": "w",
    }
    base.update(kw)
    return base


def test_sanitize_keeps_valid():
    out = ds._sanitize({"recommendations": [_rec()], "note": ""})
    assert len(out["recommendations"]) == 1
    assert out["recommendations"][0]["url"] == "https://x.org/a"


def test_sanitize_drops_bad_enum():
    out = ds._sanitize({"recommendations": [_rec(format="DOCX"), _rec(level="중2")], "note": ""})
    assert out["recommendations"] == []


def test_sanitize_drops_non_http_url():
    out = ds._sanitize({"recommendations": [_rec(url="ftp://x"), _rec(url="")], "note": ""})
    assert out["recommendations"] == []


def test_sanitize_drops_missing_title():
    out = ds._sanitize({"recommendations": [_rec(title="  ")], "note": ""})
    assert out["recommendations"] == []


def test_sanitize_caps_at_max():
    recs = [_rec(url=f"https://x.org/{i}") for i in range(MAX := ds.MAX_RECOMMENDATIONS + 3)]
    out = ds._sanitize({"recommendations": recs, "note": ""})
    assert len(out["recommendations"]) == ds.MAX_RECOMMENDATIONS


def test_sanitize_note_non_string():
    out = ds._sanitize({"recommendations": [], "note": 123})
    assert out["note"] == ""


# ── verify_urls: httpx mock ───────────────────────────────────────────────

class _Resp:
    def __init__(self, status, ctype="text/html", url="https://x.org/a"):
        self.status_code = status
        self.headers = {"content-type": ctype}
        self.url = url


def _mock_transport(handler):
    return httpx.MockTransport(handler)


@pytest.mark.asyncio
async def test_verify_pdf_passes_on_pdf_ctype(monkeypatch):
    async def fake_head(self, url, **kw):
        return httpx.Response(200, headers={"content-type": "application/pdf"}, request=httpx.Request("HEAD", url))
    monkeypatch.setattr(httpx.AsyncClient, "head", fake_head)
    kept = await ds.verify_urls([_rec(format="PDF", url="https://x.org/a.pdf")])
    assert len(kept) == 1


@pytest.mark.asyncio
async def test_verify_pdf_drops_html(monkeypatch):
    async def fake_head(self, url, **kw):
        return httpx.Response(200, headers={"content-type": "text/html"}, request=httpx.Request("HEAD", url))
    async def fake_get(self, url, **kw):
        return httpx.Response(200, headers={"content-type": "text/html"}, request=httpx.Request("GET", url))
    monkeypatch.setattr(httpx.AsyncClient, "head", fake_head)
    monkeypatch.setattr(httpx.AsyncClient, "get", fake_get)
    kept = await ds.verify_urls([_rec(format="PDF", url="https://x.org/notpdf")])
    assert kept == []


@pytest.mark.asyncio
async def test_verify_webpage_passes_on_200(monkeypatch):
    async def fake_head(self, url, **kw):
        return httpx.Response(200, headers={"content-type": "text/html"}, request=httpx.Request("HEAD", url))
    monkeypatch.setattr(httpx.AsyncClient, "head", fake_head)
    kept = await ds.verify_urls([_rec(format="웹페이지", url="https://x.org/page")])
    assert len(kept) == 1


@pytest.mark.asyncio
async def test_verify_drops_dead(monkeypatch):
    async def fake_head(self, url, **kw):
        return httpx.Response(404, request=httpx.Request("HEAD", url))
    async def fake_get(self, url, **kw):
        return httpx.Response(404, request=httpx.Request("GET", url))
    monkeypatch.setattr(httpx.AsyncClient, "head", fake_head)
    monkeypatch.setattr(httpx.AsyncClient, "get", fake_get)
    kept = await ds.verify_urls([_rec(format="웹페이지", url="https://x.org/dead")])
    assert kept == []


@pytest.mark.asyncio
async def test_verify_network_error_dropped(monkeypatch):
    async def fake_head(self, url, **kw):
        raise httpx.ConnectError("boom")
    monkeypatch.setattr(httpx.AsyncClient, "head", fake_head)
    kept = await ds.verify_urls([_rec(format="웹페이지", url="https://x.org/err")])
    assert kept == []


@pytest.mark.asyncio
async def test_verify_empty_noop():
    assert await ds.verify_urls([]) == []


# ── _count_server_tools: 턴별 서버툴 계측 ─────────────────────────────────

class _Block:
    def __init__(self, type, name=None):
        self.type = type
        self.name = name


def test_count_server_tools_mixed():
    content = [
        _Block("text"),
        _Block("server_tool_use", "web_search"),
        _Block("server_tool_use", "web_fetch"),
        _Block("server_tool_use", "web_fetch"),
        _Block("web_search_tool_result"),
    ]
    assert ds._count_server_tools(content) == (1, 2)


def test_count_server_tools_none():
    assert ds._count_server_tools([_Block("text"), _Block("web_fetch_tool_result")]) == (0, 0)
    assert ds._count_server_tools([]) == (0, 0)


# ── _tools: web_fetch 제외 회귀 가드 (latency 결정 고정) ───────────────────

def test_tools_search_only_no_fetch():
    """web_fetch는 latency 주범이라 hot path에서 제거됐다(2026-06-25). 재유입 방지."""
    names = [t["name"] for t in ds._tools()]
    assert names == ["web_search"]
    assert all(t["type"] != "web_fetch_20260209" for t in ds._tools())


def test_web_search_forces_direct_caller():
    """allowed_callers=['direct'] 없으면 sonnet-4-6이 web_search를 code_execution으로 감싸
    programmatic 호출 → 90s+ 헛돌이(2026-06-25 재현). 이 불변식이 깨지면 다시 느려진다."""
    ws = ds._tools()[0]
    assert ws["allowed_callers"] == ["direct"]


# ── _clean_suggestions: 제안 프롬프트 정규화 ──────────────────────────────

def test_clean_suggestions_dedup_and_strip():
    raw = ["  공부 A  ", "공부 A", "공부 B", "", "   "]
    assert ds._clean_suggestions(raw) == ["공부 A", "공부 B"]


def test_clean_suggestions_caps_at_limit():
    raw = [f"주제 {i}" for i in range(ds.SUGGEST_COUNT + 3)]
    assert len(ds._clean_suggestions(raw)) == ds.SUGGEST_COUNT


def test_clean_suggestions_drops_non_string_and_non_list():
    assert ds._clean_suggestions(["ok", 1, None, {"x": 1}]) == ["ok"]
    assert ds._clean_suggestions("not a list") == []
    assert ds._clean_suggestions(None) == []


def test_clean_suggestions_drops_over_max_chars():
    """장황한 제안(>10자)은 떨군다 — 칩·placeholder가 한 줄이라."""
    raw = ["양자역학", "머신러닝 심화 과정을 공부하고 싶어요", "행렬분해"]
    assert ds._clean_suggestions(raw, max_chars=10) == ["양자역학", "행렬분해"]
    # max_chars 미지정이면 길이 제한 없음(하위호환)
    assert len(ds._clean_suggestions(raw)) == 3
