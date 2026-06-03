# Postmortem: 비-ASCII 파일명 PDF가 뷰어에 안 보임

**발생/해결일**: 2026-06-03
**심각도**: 높음 (해당 교재 사용 불가, 영구 빈 화면)
**상태**: 해결 — backend 배포 완료(`1fd015c`), iOS v1.0.1/build 5 머지(`62a98f5`)
**영향 범위**: 파일명에 비-ASCII 문자(한글·아랍어 등)가 들어간 교재 PDF. 운영 기준 교재 16개 중 5개. ASCII 파일명(영어 교재·논문)은 정상.

## 증상

iPad 앱에서 한글/아랍어 파일명 교재(`2026 수능완성 아랍어 I.pdf`, `ماضٍ صارِمٌ.pdf`)를 PDF 뷰어로 열면 빈 화면. 영어 파일명 교재(`Attention is all you need.pdf`, `roberts_grammar.pdf` 등)는 정상. 한 번 안 보인 교재는 백엔드를 고친 뒤에도 계속 빈 화면.

## 근본 원인 (두 겹)

### 1) 백엔드 — 응답 헤더 직렬화 500

`serve_pdf_file`(`backend/app/routers/pdf.py`)이 S3 백엔드에서 타는 `StreamingResponse` 분기가 `Content-Disposition` 헤더를 직접 조립하면서 파일명을 날것으로 넣었다:

```python
headers={"Content-Disposition": f'inline; filename="{source.file_name}"'}
```

HTTP 헤더 값은 RFC 7230상 **latin-1(ISO-8859-1)로만 인코딩**된다. starlette가 응답 직렬화 시 `v.encode("latin-1")`를 수행하는데, 한글/아랍어는 latin-1 문자표에 없어 `UnicodeEncodeError` → **500 Internal Server Error** (바디 전송 시작 전, `latency≈2ms`로 즉사).

- **트리거는 PDF 내용이 아니라 파일명 문자셋.** ASCII 파일명은 latin-1 인코딩 성공 → 200. 비-ASCII만 500.
- **로컬(개발)에선 재현 안 됨**: 로컬은 `FileResponse` 분기를 타는데, starlette `FileResponse`는 내부적으로 RFC 5987(`filename*=UTF-8''…`)로 파일명을 안전 인코딩한다. 운영은 `STORAGE_BACKEND=s3`라 항상 `StreamingResponse` 분기 → 100% 발생. (환경별 분기 차이가 재현을 가렸다.)
- 소스 PDF 자체는 무결(`%PDF-1.7`, 128p, 파싱 정상)했다 — 데이터 문제 아님.

### 2) iOS — 에러 응답을 PDF로 캐싱

`PdfViewerView.loadPdfData`가 공용 `APIClient`를 우회해 `URLSession`을 직접 호출하고 **HTTP status를 검사하지 않았다**:

```swift
let (data, _) = try await URLSession.shared.data(from: ...)  // 500이어도 throw 안 함
try data.write(to: cachedFile)                                // 에러 본문을 pdf_<id>.pdf로 저장
```

`URLSession.data`는 500/401 등에 throw하지 않고 에러 본문을 `data`로 반환한다. 그 본문이 `pdf_<textbookId>.pdf`에 그대로 저장되고, 이후엔 `fileExists`가 true라 영원히 "cache hit" → `PDFDocument`가 파싱 실패 → 빈 화면. **한 번 오염되면 백엔드를 고쳐도 재다운로드하지 않는다.** 이 때문에 backend 수정 후에도 기존 기기는 계속 빈 화면이었다.

`/file`이 `?token=<JWT>` 쿼리파라미터로 인증한 것도 같은 우회의 부산물로, **access 로그에 전체 JWT가 노출**되는 부수적 문제도 있었다.

## 탐지

운영 로그에서 `GET /api/pdf/{id}/file -> 500` + 트레이스백(`UnicodeEncodeError: 'latin-1' codec can't encode characters`)을 확인. 동시에 `/file` 요청이 거의 없고 FE가 `[pdf] cache hit`만 반복하는 패턴으로 클라 캐시 오염을 식별.

## 수정

### 백엔드 (`1fd015c`)
`StreamingResponse` 분기의 `Content-Disposition`을 RFC 5987로 인코딩:

```python
from urllib.parse import quote
"Content-Disposition": f"inline; filename*=UTF-8''{quote(source.file_name)}"
```

회귀 테스트(`backend/tests/test_pdf.py::test_serve_pdf_file_non_ascii_filename_streaming`): `storage.local_path→None` 패치로 운영 S3 경로를 강제해 비-ASCII 파일명 200 + 헤더 인코딩 검증.

### iOS (`62a98f5`, v1.0.1/build 5)
`PdfViewerView`의 ad-hoc URLSession 호출 3곳을 공용 `APIClient`로 통합:
- `/file` → `APIClient.getData()` — 공용 status 가드(`guard 200..<300 else throw`)와 `Authorization` 헤더 상속, `?token=` 폐기(로그 JWT 누출 제거). 백엔드는 헤더 인증을 우선 처리하므로 변경 불필요.
- 캐시 읽기/다운로드 모두 `PDFDocument(data:)` 파싱 검증 후에만 사용·저장. 파싱 실패 캐시는 evict 후 재다운로드 → **기존 오염 캐시 자가치유**.
- 가이드/챕터 챗 2곳도 `APIClient.postCodable()`로 흡수.

## 재발 방지 / 교훈

- **응답 헤더에 사용자 제어 문자열을 직접 넣지 말 것** — 파일명·제목 등은 프레임워크 헬퍼나 RFC 5987 인코딩을 거친다.
- **환경 분기(Local vs S3)가 동일 코드 경로의 버그를 가린다** — 로컬에서만 검증하면 운영 전용 분기는 못 잡는다. S3 경로를 강제하는 테스트를 둔다.
- **클라이언트는 절대 비-2xx 응답을 영속화하지 않는다** — HTTP 네트워킹은 단일 클라이언트(`APIClient`)로 일원화해 status 검사·인증·로깅 규율을 한 곳에 둔다. ad-hoc `URLSession` 직접 호출 금지.
- **캐시는 "있다"가 아니라 "유효하다"로 판단** — 캐시 히트도 콘텐츠 유효성(여기선 PDF 파싱)을 검증해 오염 캐시를 자가치유한다.

## 후속 (선택)
- 백엔드 `/file`의 `?token=` 쿼리파라미터 인증 자체를 제거 검토 (현재는 레거시 호환으로 유지, iOS는 더 이상 사용 안 함).
