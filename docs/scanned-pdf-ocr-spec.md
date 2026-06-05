# 스캔본(이미지) PDF OCR 지원 Spec

> **Status:** Implemented (Tracks A–D, 2026-06-05). 켜기 전 §1.4 체크리스트 필수: `ENABLE_OCR=true` + OCR 예산 양수.
> **Date:** 2026-06-05
> **Author:** (auto-generated)
> **Scope:** `backend/` (주), `ios-app/` (진행률 UI)

---

## 1. Background

### 1.1 현재 상태 / 문제

백엔드는 PDF를 전부 PyMuPDF `page.get_text()`(텍스트 레이어)로만 읽는다. 이미지 렌더링·OCR 코드는 전혀 없다 (`pdf_service.py:84-102`). 따라서 **텍스트 레이어가 없는 스캔본(이미지) PDF**는 `extract_text()`가 빈 문자열을 반환하고, 그 하나의 근본 원인이 다운스트림 전체를 무너뜨린다:

| 지점 | 코드 | 스캔본 결과 |
|---|---|---|
| 챕터 LLM 감지 | `chapter_service.py:33-66` ← `extract_page_headers()` (`pdf_service.py:70-81`) | 헤더 빈 문자열 → 감지 실패 |
| 페이지 가이드 | `pdf.py:368` | `400 "Page has no extractable text"` |
| 챕터 가이드/CoT | `pdf.py:481` | `400 "Chapter has no extractable text"` |
| 인덱싱(RAG) | `indexing_service.py:31-41` | 빈 페이지 필터 → chunks=0 |
| 피드백 컨텍스트 | `feedback.py:88-145` | 빈 컨텍스트 → RAG 폴백도 빈 결과 |

**타깃 유저(대학생)·핵심 콘텐츠(절판 고전어 교재)에서 스캔본은 엣지케이스가 아니라 핵심 유스케이스**다. 학생 개인 보유 스캔본 활용 시나리오도 동일.

### 1.2 합의된 설계 결정 (대화에서 확정)

- **단일 수정 지점**: 근본 원인이 하나(`extract_text` 빈 반환)이므로, `extract_text`를 OCR-aware로 만들면 다운스트림(챕터감지/가이드/피드백/챗)이 **코드 변경 없이** 동작한다.
- **OCR 엔진 = Claude Vision (Haiku)**. 이미 anthropic SDK가 통합돼 있어(`feedback_service`, `guide_service`) 신규 벤더·인증·SDK가 0. 고전어·수식·LaTeX 복원이 Naver CLOVA보다 강함. 페이지 렌더(PyMuPDF `get_pixmap` ~1568px) → Haiku에 "원문만 추출" 프롬프트. 페이지당 ~$0.006 추정. **Naver CLOVA는 탈락** (고전어/수식 약함, ncloud 정합성 실익 작음).
- **처리 시점 = eager 백그라운드 + 점진적 노출**. 업로드 시 스캔 감지 → 백그라운드 잡으로 페이지 순차 OCR → 매 페이지 즉시 DB 캐시(중단돼도 손실 0, 재개 가능) → 충분히 OCR되면 챕터 감지 → 챕터 가이드/CoT 점진 생성. 제품 요구는 **"전체가 결국 뜬다 / 빠를 필요 없다"**. lazy는 탈락(CoT는 챕터 전체 텍스트 필요, 제품이 전권 챕터 노출 요구).
- **캐싱**: 페이지 텍스트를 전용 테이블에 저장. `extract_text`가 캐시 우선 조회 → 재OCR 비용 0.
- **tier 정책** (tier 인프라 이미 존재: `get_tier` → normal/pro, `auth.py:65-68`):
  - **free(normal)**: 권당(per-textbook) OCR 페이지 **하드 캡 ~50p**. 캡은 "OCR한 페이지"에만 적용(텍스트 레이어 PDF는 캡 무관). 50p 경계는 **명시적 안내 + 업셀**("전체 인식은 Pro") — 조용히 자르지 말 것. 권당 비용 ~$0.3 상한.
  - **pro**: 풀 OCR 백그라운드. `task_type="ocr"` **별도 예산 버킷**으로 interactive(피드백/챗) 쿼터를 굶기지 않음. 큰 책은 며칠 걸쳐 완성.
- **비용/쿼터**: OCR도 Claude 호출 → `LLMUsage(task_type="ocr")`로 비용 기록 → 기존 USD-기반 쿼터(`quota.py`)에 흡수.

### 1.3 Out of Scope

| 항목 | 이유 |
|---|---|
| Naver CLOVA OCR 연동 | 엔진 결정에서 탈락 |
| 스캔본 RAG 임베딩 인덱싱 | `ENABLE_EMBEDDING=false` 기본 비활성 (CLAUDE.md). OCR 텍스트가 생기면 인덱싱은 자동으로 가능해지나, 본 스펙은 챕터/가이드/피드백 컨텍스트 복구가 목표. RAG는 별도 |
| 수식 LaTeX 렌더 품질 튜닝 | 1차는 "텍스트 복원"이 목표. LaTeX 정밀도 개선은 후속 |
| OCR 결과 사용자 수정 UI | 1차 범위 밖 |
| pro 예산 pause/resume의 정교한 스케줄링·우선순위 큐 | 1차는 인프로세스 주기 스위퍼(10분)로 "예산 회복 시 자동 재개"하는 단순형. 우선순위·페어니스는 후속 |

### 1.4 운영 리스크 (켜기 전 필수)

- 현재 `DAILY_COST_LIMIT_*=0`(무제한, `config.py:21-23`). **이 기능을 켜기 전 OCR 예산 한도를 양수로 설정해야 한다.** 안 그러면 스캔본 다수 업로드 = 순지출 폭증.
- 권당 페이지 상한(`OCR_MAX_PAGES_PER_BOOK`, 기본 600)을 백스톱으로 둔다 — 잘못된 TOC로 거대 범위가 잡혀도 비용 캡.

---

## 2. 목표 플로우

```
업로드 (/api/pdf/upload)
  │
  ├─ save_pdf → total_pages, content_hash
  │
  ├─ 스캔 감지: 전 페이지 get_text() 문자수 / 페이지수 < THRESHOLD → is_scanned=true
  │
  ├─ is_scanned=false → 기존 플로우 (변경 없음)
  │
  └─ is_scanned=true → ocr_status="pending", 백그라운드 OCR 잡 등록
                          │
       ┌──────────────────┘
       ▼
  [백그라운드 OCR 잡]  async_session()
   for page in 1..min(total_pages, cap):     # cap = tier별 (free 50 / pro 600)
     if ocr_page_text(textbook,page) 존재 → skip (재개)
     pixmap = render(page, ~1568px)
     text   = haiku_vision_ocr(pixmap)        # "원문만" 프롬프트
     INSERT ocr_page_text(textbook,page,text) # 매 페이지 즉시 커밋 → 손실 0
     log_llm_usage(task_type="ocr", cost...)  # 쿼터 반영
     if 쿼터(OCR 버킷) 초과 → ocr_status="paused", break  # 다음 사이클 재개
     ocr_pages_done++
   ocr_status = "complete" | "capped" | "paused"
       │
       ├─ 충분히 OCR됨 → 챕터 감지 (extract_page_headers 가 이제 OCR 텍스트 사용)
       │
       └─ 챕터/페이지 가이드: 요청 시 extract_text → 캐시 hit → 정상 생성

  iOS: GET /api/pdf/{id}/status 폴링 → 진행률/capped 표시 + Pro 업셀
```

`extract_text(key, start, end)` 분기 (핵심):
```
def extract_text(textbook, start, end):
    if not is_scanned(textbook):
        return PyMuPDF get_text()              # 기존
    rows = SELECT ocr_page_text WHERE page in [start,end]
    return "\n".join(rows by page)             # 캐시. 없는 페이지는 누락 표시
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/pdf/upload` | 업로드 + 스캔감지 분기 | 변경 | §3.2-a |
| GET | `/api/pdf/{id}/status` | OCR/인덱싱 진행 상태 | **신규** | §3.2-b |
| GET | `/api/pdf/{id}/chapters` | 챕터 목록 | 변경없음(데이터만 점진) | — |
| GET | `/api/pdf/{id}/guide` | 페이지 가이드 | 변경(쿼터+capped 에러) | §3.2-c |
| GET | `/api/pdf/{id}/chapter-guide` | 챕터 가이드/CoT | 변경(쿼터+capped 에러) | §3.2-c |

### 3.2 신규/변경 엔드포인트 계약 (동결)

#### 3.2-a POST /api/pdf/upload
- Request: 기존과 동일 (multipart `file`, form `note_id?`). 변경 없음.
- Response 200: 기존 필드 + `is_scanned: bool`, `ocr_status: "pending"|null`
  - `is_scanned=true`면 `indexing` 의미가 OCR 진행을 포함. iOS는 `is_scanned=true`일 때 status 폴링 시작.
- 예시: `{ "id": "uuid", "total_pages": 312, "is_scanned": true, "ocr_status": "pending", "indexing": "started" }`
- 텍스트 PDF면: `{ "id": "uuid", "total_pages": 120, "is_scanned": false, "ocr_status": null, "indexing": "started" }`

#### 3.2-b GET /api/pdf/{id}/status (신규)
- Request: path `id` (textbook id)
- Response 200:
  ```
  {
    "is_scanned": bool,
    "ocr_status": "pending"|"running"|"paused"|"error"|"capped"|"complete"|null,  // 텍스트PDF는 null
    "ocr_pages_done": int,        // OCR 완료 페이지 수
    "ocr_pages_total": int,       // 이번 tier에서 OCR 대상 페이지 수 = min(total_pages, cap)
    "total_pages": int,
    "capped": bool,               // free 캡에 걸렸나 (ocr_status=="capped")
    "cap_limit": int|null,        // 적용된 캡 (free=50, pro=null)
    "chapters_ready": bool        // 챕터 감지 완료 여부
  }
  ```
- Error: 404 — textbook 없음 / 타 유저 소유
- 예시(진행 중): `{ "is_scanned": true, "ocr_status": "running", "ocr_pages_done": 47, "ocr_pages_total": 312, "total_pages": 312, "capped": false, "cap_limit": null, "chapters_ready": false }`
- 예시(free 캡): `{ "is_scanned": true, "ocr_status": "capped", "ocr_pages_done": 50, "ocr_pages_total": 50, "total_pages": 312, "capped": true, "cap_limit": 50, "chapters_ready": true }`
- MSW 해당 없음(iOS) — iOS는 이 계약으로 `PdfStatus` Decodable 모델 선작성.

#### 3.2-c GET /api/pdf/{id}/guide, /chapter-guide (변경)
- Request: 기존과 동일.
- 성공 Response: 기존과 동일 (`PageGuideResponse`/`ChapterGuideResponse`).
- **신규 Error 409 `ocr_incomplete`**: 요청한 페이지/챕터가 아직 OCR 안 됨(스캔본 처리 중) 또는 free 캡 너머.
  ```
  { "detail": "OCR not complete for this page/chapter",
    "code": "ocr_incomplete",
    "ocr_status": "running"|"paused"|"error"|"capped",
    "capped": bool,            // true면 Pro 업셀 트리거
    "page": int|null }
  ```
- **기존 400 "no extractable text"는 유지** (텍스트PDF의 진짜 빈 페이지). 스캔본은 409로 구분.
- 신규 Error 429 `quota_exceeded`: 기존 `quota.py` 형식 (가이드 라우터에 쿼터 추가됨에 따라).

---

## 4. 구현 설계

### 4.1 데이터 모델 변경

**4.1-a 신규 테이블 `ocr_page_text`** (`app/models/ocr.py`)
```
id          String PK (uuid)
textbook_id String FK textbook_sources.id, indexed
page        Integer                      # 1-indexed
content     Text                         # OCR 추출 원문 (null 바이트 제거)
created_at  DateTime
UNIQUE (textbook_id, page)               # 재OCR 멱등 / 재개 skip 판정
```
- 전용 테이블 채택 이유: `DocumentChunk`는 청크 단위(임베딩용)라 페이지 1:1이 아님(`document.py:13-27`). OCR 캐시는 페이지 1:1이라야 `extract_text` 분기·재개 skip이 단순.

**4.1-b `TextbookSource` 컬럼 추가** (`app/models/textbook.py:10-22`)
```
is_scanned      Boolean default False
ocr_status      String  nullable   # pending|running|paused|error|capped|complete
ocr_pages_done  Integer default 0
ocr_cap         Integer nullable   # 이 책에 적용된 캡 (free=50, pro=600)
ocr_updated_at  DateTime nullable  # 하트비트. running이 페이지마다 갱신 → stale면 프로세스 사망 판별
```
- 현재 상태 플래그가 없고 `DocumentChunk` count로 추론(`pdf.py:102-107`)하지만, OCR 진행률엔 명시 컬럼이 필요.

**4.1-c Alembic 마이그레이션** 1개: `ocr_page_text` 생성 + `textbook_sources` 컬럼 4개 추가. (CLAUDE.md: 배포 시 app startup CMD가 자동 적용 — 메모리 `alembic_autoapply_on_deploy`.)

### 4.2 OCR 서비스 (신규 `app/services/ocr_service.py`)
- `render_page(doc, page_idx) -> bytes`: PyMuPDF `page.get_pixmap(matrix=...)`로 장변 ~1568px PNG/JPEG. (Claude 이미지 리사이즈 상한과 일치 — 토큰 절약)
- `async ocr_page(image_bytes) -> (text, usage)`: Haiku Vision 호출. 시스템 프롬프트 = **"이미지의 텍스트를 원문 그대로 추출. 설명·요약·마크다운·코드펜스 금지. 표/수식은 가능한 평문으로. 빈 페이지면 빈 문자열."** `MODEL_PRICING`(`feedback_service.py:68-71`)로 비용 산출.
- null 바이트 제거(`indexing_service.py:34` 패턴 재사용).

### 4.3 LLMUsage 헬퍼 추출 (`app/services/usage_service.py` 또는 feedback_service 내)
- 현재 라우터에서 인라인 `db.add(LLMUsage(...))`(`feedback.py:150-178,413-424`). OCR 잡(라우터 밖 백그라운드)에서도 기록해야 하므로 **공용 헬퍼 추출**:
  `async def log_llm_usage(db, user_id, model, usage, *, task_type, cost_usd, latency_ms, ...)`.
- 기존 호출부도 이 헬퍼로 치환(리팩토링, 동작 동일). `task_type` 값에 `"ocr"` 추가.

### 4.4 스캔 감지 (`pdf_service.py` 또는 upload 라우터)
- `is_scanned_pdf(key, total_pages) -> bool`: 샘플 페이지(또는 전체)의 `get_text()` 총 문자수 / 페이지수 < `OCR_SCAN_TEXT_THRESHOLD`(기본 예: 30자/페이지)면 스캔본. 표지/빈페이지 영향 줄이려 중앙 N페이지 샘플링 고려.

### 4.5 백그라운드 OCR 잡 (`pdf.py` `_background_ocr`)
- `BackgroundTasks.add_task` + `async with async_session()`(기존 `_background_index` 패턴 `pdf.py:31-38`).
- tier별 cap 결정: free=`OCR_FREE_CAP_PAGES`(50), pro=`OCR_MAX_PAGES_PER_BOOK`(600). `ocr_cap` 저장.
- 루프: 페이지별 캐시 존재 skip(재개) → 렌더 → OCR → `ocr_page_text` INSERT + 커밋 → `log_llm_usage` → `ocr_pages_done++` → OCR 쿼터 버킷 초과 시 `paused` break.
- 종료 상태: 전부 완료=`complete`, free 캡 도달=`capped`, 쿼터 정지=`paused`, 예외=`error`.
- 완료/충분 시 챕터 감지 트리거(기존 `_background_detect_chapters` 재사용, `extract_page_headers`가 OCR 텍스트를 읽도록 §4.6).
- **중복 방지(워커 2개)**: 잡 시작 시 `UPDATE … SET ocr_status='running' WHERE ocr_status IN (pending,paused,error) RETURNING`으로 원자적 claim. 0행이면 타 워커가 처리 중 → 즉시 반환.
- **자동 재개(`_ocr_sweeper_loop`, app startup)**: 10분 주기로 (1) 하트비트 끊긴 `running`을 `error`로 강등 → (2) `paused`(예산 회복 시)·`error`를 원자 claim 후 재개. 예산은 KST 자정에 풀리므로 앱을 안 열어도 그 주기 안에 이어받는다. cron 등 외부 인프라 불필요.

### 4.6 `extract_text` / `extract_page_headers` OCR 분기 (`pdf_service.py`)
- `extract_text(textbook_or_key, start, end)`: `is_scanned`면 `ocr_page_text`에서 조회. 미존재 페이지는 누락. **시그니처 변경 주의** — 현재는 `key`(경로)만 받음(`pdf_service.py:84`). textbook 메타(is_scanned)와 db 세션 접근이 필요 → 호출부(`feedback.py`, `pdf.py` 가이드) 함께 수정. 호출부가 많으므로 **래퍼 함수**로 흡수 권장.
- `extract_page_headers`도 동일 분기(챕터 감지가 OCR 텍스트 상단 N줄 사용).

### 4.7 tier 캡 게이팅 & 가이드 라우터 쿼터
- 가이드 라우터(`pdf.py` 페이지/챕터 가이드)에 **`check_daily_quota` 추가**(현재 없음). OCR/가이드 비용 보호.
- 가이드 요청 시 대상 페이지/챕터가 `ocr_page_text`에 없으면:
  - `ocr_status in (running,paused)` → 409 `ocr_incomplete`, `capped=false`.
  - `ocr_status==capped` 이고 요청이 캡 너머 → 409 `ocr_incomplete`, `capped=true` (업셀).

### 4.8 OCR 쿼터 버킷 (`quota.py`, `config.py`)
- `config.py`: `DAILY_COST_LIMIT_OCR_PRO_USD`(pro OCR 일일 예산), `OCR_FREE_CAP_PAGES=50`, `OCR_MAX_PAGES_PER_BOOK=600`, `OCR_SCAN_TEXT_THRESHOLD`, `ENABLE_OCR`(기능 토글, 기본 false).
- `quota.py`: `task_type="ocr"` 비용만 합산하는 별도 체크(`check_ocr_quota`) — interactive 쿼터와 분리. free는 캡으로 통제하므로 OCR 쿼터는 주로 pro 백그라운드 페이싱용.

---

## 5. 구현 단계 (Tracks)

```
            ┌─ Track A: 모델 + 마이그레이션 + config (기반)
시작 ───────┤
            └─ (A 완료 후)
                 ├─ Track B: OCR 서비스 + 백그라운드 잡 + 스캔감지 + extract_text 분기
                 │       (B 내부: B1 OCR서비스 → B2 extract_text분기 → B3 백그라운드잡 → B4 챕터감지연동)
                 ├─ Track C: 쿼터버킷 + 가이드라우터 쿼터/capped + status API
                 │       (C는 A 완료 후 B와 병렬 가능 — 파일 다름. 단 status API는 A 컬럼 의존)
                 └─ (C status 계약 동결 후)
                       └─ Track D: iOS status 폴링 + 진행률 UI + Pro 업셀
```

**트랙 간 의존성:**
- **A → B, A → C**: 모델/마이그레이션/config가 모든 것의 기반.
- **B ↔ C**: 파일이 대부분 분리(B=services+백그라운드, C=quota+라우터). `pdf.py` 가이드 라우터는 C가 주로 수정, B는 `_background_ocr` 추가 — 같은 파일이나 다른 함수. 병합 충돌 소수, 같은 트랙 묶을 필요 없음.
- **C(§3.2-b status 계약) → D**: status 계약 동결 후 iOS가 `PdfStatus` 모델·폴링 작성. 계약은 §3.2-b에 동결됨 → D는 백엔드 구현 완료 전 착수 가능(실제 통합 테스트만 C 완료 필요).

**인원별 배분:**
| 인원 | 배분 |
|---|---|
| 1명 | A → B → C → D 순차 |
| 2명 | P1: A→B, P2: (A 후) C→D |
| 3명 | P1: A→B(서비스/잡), P2: C(쿼터/라우터/status), P3: D(iOS, 계약 동결 후) |

### Track A: 모델 · 마이그레이션 · config
**의존:** 없음 (기반)
**내부 순서:** A-1 → A-2 (모델 먼저) → A-3
**작업량:** 작음
| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `app/models/ocr.py` (신규) | `OcrPageText` 모델 (§4.1-a) |
| A-2 | `app/models/textbook.py` | `is_scanned/ocr_status/ocr_pages_done/ocr_cap` 컬럼 (§4.1-b) |
| A-3 | `alembic/versions/*` | 마이그레이션 1개 (테이블+컬럼). env.py 모델 import 확인(메모리 `alembic_baseline`) |
| A-4 | `app/core/config.py` | `ENABLE_OCR`, `DAILY_COST_LIMIT_OCR_PRO_USD`, `OCR_FREE_CAP_PAGES`, `OCR_MAX_PAGES_PER_BOOK`, `OCR_SCAN_TEXT_THRESHOLD` (§4.8) |

### Track B: OCR 서비스 · 백그라운드 · extract_text 분기
**의존:** Track A 완료
**내부 순서:** B-1 → B-2 → B-3 → B-4
**작업량:** 큼. 가장 복잡: B-2(extract_text 시그니처 변경 + 다수 호출부 흡수), B-3(재개 가능 잡 + 쿼터 정지)
| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `app/services/ocr_service.py` (신규) | render_page + Haiku Vision OCR + 프롬프트 + 비용 (§4.2) |
| B-1b | `app/services/usage_service.py` (신규/추출) | `log_llm_usage` 헬퍼 + 기존 인라인 치환 (§4.3) |
| B-2 | `app/services/pdf_service.py` | `is_scanned_pdf`, `extract_text`/`extract_page_headers` OCR 분기 (§4.4, §4.6). 호출부(`feedback.py`, `pdf.py`) 래퍼로 흡수 |
| B-3 | `app/routers/pdf.py` | `_background_ocr` 잡 + upload 분기(스캔감지→ocr_status=pending→등록) (§4.5). 업로드 응답에 `is_scanned/ocr_status` 추가 (§3.2-a) |
| B-4 | `app/routers/pdf.py`, `chapter_service.py` | OCR 완료 후 챕터 감지 트리거 순서 (§4.5 끝) |

### Track C: 쿼터 버킷 · 가이드 라우터 · status API
**의존:** Track A 완료 (status는 A 컬럼 의존)
**내부 순서:** C-1, C-2, C-3 대체로 병렬 가능
**작업량:** 중간
| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `app/core/quota.py` | `check_ocr_quota` (task_type="ocr" 분리 합산) (§4.8) |
| C-2 | `app/routers/pdf.py` 가이드 | 페이지/챕터 가이드에 `check_daily_quota` 추가 + 스캔본 미완 시 409 `ocr_incomplete`/capped (§4.7, §3.2-c) |
| C-3 | `app/routers/pdf.py` | `GET /api/pdf/{id}/status` 신규 + `PdfStatusResponse` (§3.2-b) |

### Track D: iOS 진행률 UI
**의존:** §3.2-b status 계약 동결(완료) → 착수 가능. 통합 검증은 Track C 완료 필요.
**내부 순서:** D-1 → D-2 → D-3
**작업량:** 중간
| ID | 파일 | 내용 |
|---|---|---|
| D-1 | `Models/AIResponse.swift` (또는 신규) | `PdfStatus` Decodable (§3.2-b 계약) |
| D-2 | `Services/APIClient.swift` | `getPdfStatus(id)` + 폴링 헬퍼 |
| D-3 | `Views/PdfViewerView.swift`, `CreateNoteSheet.swift`/`NoteMetaSheet.swift` | 스캔본 진행률 표시(`ocr_pages_done/total`), `capped` 시 Pro 업셀, 가이드 409 `ocr_incomplete` 처리(재시도 안내) |

---

## 6. 확인 완료 사항 (코드 검증)

- `extract_text`는 현재 `key`(경로)만 받고 `get_text()`만 호출, OCR 없음 — `backend/app/services/pdf_service.py:84-102`. `_open_pdf:16-25`, `extract_toc:59-67`, `extract_page_headers:70-81`.
- 가이드 빈 텍스트 시 400 — 페이지 `pdf.py:368`, 챕터 `pdf.py:481`. 가이드 라우터에 **쿼터 체크 없음**.
- 챕터 감지: `pdf.py:41-64,149-168` + `chapter_service.py:33-66` (헤더→Haiku).
- 피드백 컨텍스트 우선순위 1/2/3 — `feedback.py:88-145`. RAG 폴백은 `if textbook_id and not context_parts`.
- 쿼터: USD 비용 기반, KST 자정, advisory lock, 429 — `quota.py`. tier 한도 `config.py:21-23`(기본 0=무제한). `get_tier` `auth.py:65-68`. 호출부 `feedback.py:68,291`.
- LLMUsage 인라인 기록(헬퍼 없음) — `feedback.py:150-178,413-424`. 모델 `usage.py:10-27`, `task_type` 현재값: complex/simple/page_guide/chapter_guide/chat.
- 비용 추정 `feedback_service.py:67-103`, `MODEL_PRICING:68-71`.
- `TextbookSource` 상태 플래그 없음, `total_pages` 존재 — `textbook.py:10-22`. 인덱싱 상태는 `DocumentChunk` count 추론 `pdf.py:102-107`.
- `DocumentChunk`에 `page_start/page_end/content/embedding` — `document.py:13-27` (청크 단위, 페이지 1:1 아님 → 전용 테이블 채택 근거).
- 백그라운드 패턴: `async with async_session()` + `BackgroundTasks.add_task` — `pdf.py:31-38,173`.
- iOS 가이드/챕터 호출 — `PdfViewerView.swift:665-714`, 모델 `AIResponse.swift:45-93`. 업로드 진행률 UI **없음**(텍스트만) — `CreateNoteSheet.swift:182`, `NoteMetaSheet.swift:122`. APIClient `get`/`uploadFile`/`getData` — `APIClient.swift:59-213`.

### 6.x 미확인 / 결정 필요

| # | 항목 | 확인/결정 방법 |
|---|---|---|
| 1 | `OCR_SCAN_TEXT_THRESHOLD` 구체값 | 실제 스캔본/텍스트PDF 샘플로 문자/페이지 분포 측정 |
| 2 | Haiku Vision OCR 실측 품질·토큰 (고전어/수식) | 샘플 1~2페이지 PoC — 토큰·비용·정확도 확인 후 페이지당 비용 확정 |
| 3 | 렌더 해상도/포맷(JPEG vs PNG, DPI) | PoC로 인식률 대비 용량 균형 |
| 4 | free 50p 캡: 권당 누적 vs 일일 | 권당(per-textbook) 누적으로 합의됨. `ocr_cap`/`ocr_pages_done`로 구현 |
| 5 | 부분 챕터(capped 경계 걸친 챕터) 가이드 처리 | 캡 내 페이지만으로 생성할지 vs 409. 1차는 챕터 전체가 캡 내일 때만 생성 권장 |
| 6 | extract_text 시그니처 변경 범위 | 호출부 전수(`feedback.py`, `pdf.py`) grep 후 래퍼 설계 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 무제한 쿼터(0)로 OCR 켜면 비용 폭증 | 높음 | `ENABLE_OCR` 토글 + OCR 예산 양수 설정 강제(§1.4). 켜기 전 체크리스트 |
| Haiku OCR 품질이 고전어/수식에서 미흡 | 중 | PoC(§6.x-2) 선행. 미흡 시 Sonnet Vision 폴백 옵션(비용↑) 검토 |
| extract_text 시그니처 변경이 호출부 광범위 | 중 | 래퍼 함수로 흡수, 텍스트PDF 경로는 동작 불변 — 회귀 테스트 |
| 백그라운드 잡 중복 실행/경합 | 중 | `ocr_page_text` UNIQUE(textbook,page)로 멱등. 페이지 skip-on-exists로 재개 안전 |
| 부분 OCR 상태가 조용히 열화된 가이드 생성 | 중 | 미완 시 **409 명시**(침묵 금지 — 메모리 `telemetry_blind_spots` 교훈). status API로 진행 노출 |
| 거대 스캔본이 pro 일일 예산 독식 | 낮음 | OCR 버킷 분리 + 권당 페이지 상한 + pause/resume |
| 잘못된 TOC로 챕터 page_end가 끝까지 | 낮음 | `OCR_MAX_PAGES_PER_BOOK` 백스톱 |
