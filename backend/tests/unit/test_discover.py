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
