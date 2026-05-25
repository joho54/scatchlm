"""파일 스토리지 추상화.

`STORAGE_BACKEND=local`이면 로컬 파일시스템(`PDF_UPLOAD_DIR` 하위)을,
`STORAGE_BACKEND=s3`이면 Naver Cloud Object Storage(S3 호환)를 사용한다.

키(key)는 백엔드와 무관한 논리 경로다 (예: "pdf/<uuid>.pdf").
- 로컬: PDF_UPLOAD_DIR + key
- S3: 버킷 내 객체 키 그대로
"""
from __future__ import annotations

import logging
import os
from typing import Iterator, Protocol

from app.core.config import settings

log = logging.getLogger(__name__)


class StorageBackend(Protocol):
    def save(self, key: str, data: bytes) -> None: ...
    def read(self, key: str) -> bytes: ...
    def delete(self, key: str) -> None: ...
    def local_path(self, key: str) -> str | None:
        """로컬 백엔드일 때 실제 파일 경로를 반환. S3는 None."""
        ...
    def stream(self, key: str) -> Iterator[bytes]:
        """대용량 파일 스트리밍용 청크 이터레이터."""
        ...


class LocalStorage:
    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, key: str) -> str:
        return os.path.join(self.root, key)

    def save(self, key: str, data: bytes) -> None:
        path = self._path(key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def read(self, key: str) -> bytes:
        with open(self._path(key), "rb") as f:
            return f.read()

    def delete(self, key: str) -> None:
        try:
            os.remove(self._path(key))
        except FileNotFoundError:
            pass

    def local_path(self, key: str) -> str | None:
        return self._path(key)

    def stream(self, key: str) -> Iterator[bytes]:
        with open(self._path(key), "rb") as f:
            while chunk := f.read(64 * 1024):
                yield chunk


class ObjectStorage:
    """Naver Cloud Object Storage (S3 호환). boto3 사용."""

    def __init__(self, endpoint: str, region: str, bucket: str, access_key: str, secret_key: str):
        import boto3  # 로컬 모드에서는 import 안 함

        self.bucket = bucket
        self._client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            region_name=region,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

    def save(self, key: str, data: bytes) -> None:
        self._client.put_object(Bucket=self.bucket, Key=key, Body=data)

    def read(self, key: str) -> bytes:
        obj = self._client.get_object(Bucket=self.bucket, Key=key)
        return obj["Body"].read()

    def delete(self, key: str) -> None:
        self._client.delete_object(Bucket=self.bucket, Key=key)

    def local_path(self, key: str) -> str | None:
        return None

    def stream(self, key: str) -> Iterator[bytes]:
        obj = self._client.get_object(Bucket=self.bucket, Key=key)
        body = obj["Body"]
        try:
            for chunk in body.iter_chunks(chunk_size=64 * 1024):
                yield chunk
        finally:
            body.close()


def _build_storage() -> StorageBackend:
    backend = settings.STORAGE_BACKEND.lower()
    if backend == "s3":
        missing = [
            name for name, val in [
                ("OBJECT_STORAGE_BUCKET", settings.OBJECT_STORAGE_BUCKET),
                ("OBJECT_STORAGE_ACCESS_KEY", settings.OBJECT_STORAGE_ACCESS_KEY),
                ("OBJECT_STORAGE_SECRET_KEY", settings.OBJECT_STORAGE_SECRET_KEY),
            ] if not val
        ]
        if missing:
            raise RuntimeError(f"STORAGE_BACKEND=s3 requires: {', '.join(missing)}")
        log.info("Storage backend: ObjectStorage bucket=%s endpoint=%s",
                 settings.OBJECT_STORAGE_BUCKET, settings.OBJECT_STORAGE_ENDPOINT)
        return ObjectStorage(
            endpoint=settings.OBJECT_STORAGE_ENDPOINT,
            region=settings.OBJECT_STORAGE_REGION,
            bucket=settings.OBJECT_STORAGE_BUCKET,
            access_key=settings.OBJECT_STORAGE_ACCESS_KEY,
            secret_key=settings.OBJECT_STORAGE_SECRET_KEY,
        )

    log.info("Storage backend: LocalStorage root=%s", settings.PDF_UPLOAD_DIR)
    return LocalStorage(settings.PDF_UPLOAD_DIR)


storage: StorageBackend = _build_storage()
