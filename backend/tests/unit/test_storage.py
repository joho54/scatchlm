"""스토리지 추상화 회귀 테스트.

LocalStorage save/read/delete/stream의 기본 동작과,
ObjectStorage 분기 조건(설정 누락 시 RuntimeError)을 검증한다.
"""
from __future__ import annotations

import os

import pytest

from app.services.storage import LocalStorage, _build_storage


def test_local_storage_save_read_roundtrip(tmp_path):
    storage = LocalStorage(str(tmp_path))
    key = "pdf/sample.pdf"
    data = b"%PDF-1.4 test content"

    storage.save(key, data)
    assert storage.read(key) == data


def test_local_storage_creates_nested_dirs(tmp_path):
    """save가 키의 디렉토리 부분(예: pdf/)을 자동 생성해야 한다."""
    storage = LocalStorage(str(tmp_path))
    storage.save("nested/dir/file.bin", b"hello")
    assert (tmp_path / "nested" / "dir" / "file.bin").exists()


def test_local_storage_delete_missing_is_noop(tmp_path):
    """존재하지 않는 키 삭제는 예외 없이 무시되어야 한다 (멱등)."""
    storage = LocalStorage(str(tmp_path))
    storage.delete("does-not-exist.pdf")  # should not raise


def test_local_storage_local_path_resolves(tmp_path):
    storage = LocalStorage(str(tmp_path))
    storage.save("a.pdf", b"x")
    assert storage.local_path("a.pdf") == os.path.join(str(tmp_path), "a.pdf")


def test_local_storage_stream_chunks(tmp_path):
    storage = LocalStorage(str(tmp_path))
    payload = b"abcdefg" * 10_000  # 70KB — 64KB chunk 경계 넘김
    storage.save("big.bin", payload)

    chunks = list(storage.stream("big.bin"))
    assert b"".join(chunks) == payload
    assert len(chunks) >= 2  # 64KB 청크보다 크므로 최소 2개


def test_build_storage_requires_object_storage_creds(monkeypatch):
    """STORAGE_BACKEND=s3인데 키가 비어있으면 명확한 에러로 실패해야 한다."""
    from app.core import config

    monkeypatch.setattr(config.settings, "STORAGE_BACKEND", "s3")
    monkeypatch.setattr(config.settings, "OBJECT_STORAGE_BUCKET", "")
    monkeypatch.setattr(config.settings, "OBJECT_STORAGE_ACCESS_KEY", "")
    monkeypatch.setattr(config.settings, "OBJECT_STORAGE_SECRET_KEY", "")

    with pytest.raises(RuntimeError, match="OBJECT_STORAGE_"):
        _build_storage()


def test_build_storage_defaults_to_local(monkeypatch, tmp_path):
    """기본값(local)에서는 LocalStorage 인스턴스를 반환해야 한다."""
    from app.core import config

    monkeypatch.setattr(config.settings, "STORAGE_BACKEND", "local")
    monkeypatch.setattr(config.settings, "PDF_UPLOAD_DIR", str(tmp_path))

    backend = _build_storage()
    assert isinstance(backend, LocalStorage)
