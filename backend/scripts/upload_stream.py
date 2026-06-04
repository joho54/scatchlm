#!/usr/bin/env python3
"""stdin을 NCP Object Storage(S3 호환)로 스트리밍 업로드한다.

data-durability-spec §A.3 백업 파이프라인의 업로드 단(段). pg_dump 출력을 파이프로
받아 임시파일 없이(VM 디스크 누적 회피) 버킷에 올린다. 자격증명/엔드포인트는 app
컨테이너에 이미 주입된 `OBJECT_STORAGE_*` 환경변수를 그대로 재사용 — 신규 인프라 0.

사용:
    docker compose ... exec -T postgres pg_dump -U postgres -Fc scatchlm \
      | docker compose ... exec -T app python3 /app/scripts/upload_stream.py backups/db/scatchlm-2026-06-04.dump

upload_fileobj는 비-seekable 스트림도 멀티파트로 처리하므로 대용량도 메모리 폭주 없이 전송.
"""
import os
import sys


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: upload_stream.py <object-key>\n")
        return 2
    key = sys.argv[1]

    try:
        endpoint = os.environ["OBJECT_STORAGE_ENDPOINT"]
        region = os.environ["OBJECT_STORAGE_REGION"]
        bucket = os.environ["OBJECT_STORAGE_BUCKET"]
        access_key = os.environ["OBJECT_STORAGE_ACCESS_KEY"]
        secret_key = os.environ["OBJECT_STORAGE_SECRET_KEY"]
    except KeyError as exc:
        sys.stderr.write(f"missing env: {exc}\n")
        return 3

    import boto3

    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    # sys.stdin.buffer는 비-seekable 스트림 → upload_fileobj가 멀티파트로 분할 전송.
    client.upload_fileobj(sys.stdin.buffer, bucket, key)
    sys.stderr.write(f"uploaded s3://{bucket}/{key}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
