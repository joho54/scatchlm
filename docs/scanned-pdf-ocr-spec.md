# 스캔본(이미지) PDF OCR 지원

> **Status:** Implemented (as-built, 2026-06-05)
> **Scope:** `backend/` (주), `ios-app/` (진행률 UI)
> **켜기 전 필수(§6):** `ENABLE_OCR=true` + `DAILY_COST_LIMIT_OCR_PRO_USD` 양수 설정

이 문서는 구현 완료 후의 **as-built 명세**다. 원 설계 결정과 실제 코드를 함께 담는다.

---

## 1. 배경

### 1.1 문제

백엔드는 PDF를 PyMuPDF `page.get_text()`(텍스트 레이어)로만 읽었다. 따라서 **텍스트 레이어가 없는 스캔본(이미지) PDF**는 `extract_text()`가 빈 문자열을 반환했고, 그 단일 근본 원인이 다운스트림 전체를 무너뜨렸다 — 챕터 LLM 감지(헤더 빈 문자열), 페이지/챕터 가이드(`400 no extractable text`), 인덱싱(chunks=0), 피드백 컨텍스트(빈 컨텍스트).

타깃 유저(대학생)·핵심 콘텐츠(절판 고전어 교재)에서 스캔본은 엣지케이스가 아니라 핵심 유스케이스다.

### 1.2 설계 결정

- **단일 수정 지점**: 근본 원인이 하나(`extract_text` 빈 반환)이므로, 텍스트 추출을 OCR-aware로 만들면 다운스트림(챕터감지/가이드/피드백/챗)이 거의 코드 변경 없이 동작한다. → 신규 `extract_text_async()` 래퍼로 흡수, 기존 동기 `extract_text()`(텍스트 PDF 경로)는 불변.
- **OCR 엔진 = Claude Vision (Haiku)**. 이미 anthropic SDK가 통합돼 있어 신규 벤더·인증·SDK가 0. 고전어·수식 복원이 Naver CLOVA보다 강함. 페이지 렌더(PyMuPDF `get_pixmap`, 장변 ~1568px JPEG) → Haiku에 "원문만 추출" 프롬프트. **Naver CLOVA는 탈락**.
- **처리 시점 = eager 백그라운드 + 점진적 노출**. 업로드 시 스캔 감지 → 백그라운드 잡으로 페이지 순차 OCR → 매 페이지 즉시 DB 캐시(중단돼도 손실 0, 재개 가능) → 충분히 OCR되면 챕터 감지. 제품 요구는 **"전체가 결국 뜬다 / 빠를 필요 없다"**. (lazy는 탈락 — CoT는 챕터 전체 텍스트 필요.)
- **캐싱**: 페이지 텍스트를 전용 테이블 `ocr_page_text`에 저장. `extract_text_async`가 캐시 조회 → 재OCR 비용 0.
- **tier 정책** (`get_tier` → normal/pro):
  - **free(normal)**: 권당(per-textbook) OCR 페이지 **하드 캡 50p**(`OCR_FREE_CAP_PAGES`). 캡 경계는 **명시적 안내 + 업셀**("전체 인식은 Pro") — 조용히 자르지 않는다. 권당 비용 ~$0.3 상한.
  - **pro**: 풀 OCR 백그라운드. `task_type="ocr"` **별도 예산 버킷**으로 interactive(피드백/챗) 쿼터를 굶기지 않음. 백스톱 600p(`OCR_MAX_PAGES_PER_BOOK`).
  - **admin**(JWT `role=admin`): **무제한** — 페이지 캡(풀북=`total_pages`)·OCR 예산 모두 우회. role은 DB에 없어 업로드 시점에 `ocr_unlimited=true`로 영속화(백그라운드 잡·스위퍼가 JWT 없이 판별). 예산 우회로 `paused`되지 않으므로 스위퍼 변경 불필요.
- **비용/쿼터**: OCR도 Claude 호출 → `LLMUsage(task_type="ocr")`로 비용 기록 → 기존 USD 기반 쿼터(`quota.py`)에 흡수.
- **자동 재개**: 잡이 멈추는 3원인(예산/예외/프로세스 사망)을 구분하고, 인프로세스 주기 스위퍼가 예산 회복 시 자동 재개(§2.3). cron 등 외부 인프라 불필요.

### 1.3 Out of Scope

| 항목 | 이유 |
|---|---|
| Naver CLOVA OCR 연동 | 엔진 결정에서 탈락 |
| 스캔본 RAG 임베딩 인덱싱 | `ENABLE_EMBEDDING=false` 기본 비활성. OCR 텍스트가 생기면 인덱싱은 자동 가능해지나 본 작업 목표는 챕터/가이드/피드백 컨텍스트 복구 |
| 수식 LaTeX 렌더 품질 튜닝 | 1차는 "텍스트 복원"이 목표 |
| OCR 결과 사용자 수정 UI | 후속 |
| 스위퍼 우선순위 큐·페어니스 | 1차는 10분 주기 단순 스위퍼 |
| 노트 목록(HomeView) 행별 OCR 칩 | per-note live status 조회 필요 → 교재 선택 목록·업로드 직후·뷰어 배너로 충분히 커버 |

---

## 2. 동작

### 2.1 업로드 → OCR 플로우

```
POST /api/pdf/upload  (get_verified_payload → user_id, tier)
  │
  ├─ save_pdf → total_pages, content_hash
  ├─ 중복(content_hash) → 기존 레코드 재사용. 스캔본이 pending/paused/error면 즉시 재개 트리거
  │
  ├─ is_scanned = ENABLE_OCR && is_scanned_pdf()   # 토글 off면 항상 false → 기존 흐름
  │     is_scanned_pdf: 중앙부 최대 10p 샘플의 평균 추출 문자수 < OCR_SCAN_TEXT_THRESHOLD(30)
  │
  ├─ extract_toc(bookmarks) 있으면 챕터 저장 (스캔본도 임베디드 TOC면 동작)
  │
  ├─ is_scanned=false → (TOC 없으면) _background_detect_chapters + _background_index  ← 기존
  │
  └─ is_scanned=true:
        TextbookSource(is_scanned=true, ocr_status="pending",
                       ocr_cap = free?50:600) 저장
        BackgroundTasks: _background_ocr 등록 (+ _background_index는 no-op)
        챕터 LLM 감지는 OCR 완료 후로 연기(텍스트 레이어가 비어 있으므로)
        응답: { ..., is_scanned:true, ocr_status:"pending" }
```

### 2.2 백그라운드 OCR 잡 (`_background_ocr`)

```
async_session()
 ├─ 원자 claim: UPDATE textbook_sources SET ocr_status='running', ocr_updated_at=now
 │              WHERE id=:id AND ocr_status IN (pending,paused,error) RETURNING id
 │   → 0행이면 타 워커가 처리 중/이미 종료 → 즉시 반환  (워커 2개 중복 방지)
 │
 ├─ done_pages = SELECT ocr_page_text.page WHERE textbook=:id   # 재개용
 ├─ for page in 1..min(total_pages, ocr_cap):
 │     if page in done_pages → skip            # 재개
 │     if check_ocr_quota(user) 초과 → status="paused"; break
 │     img  = render_page(doc, page-1)          # ~1568px JPEG
 │     res  = await ocr_page(img)               # Haiku "원문만" 프롬프트
 │     INSERT ocr_page_text(page, content)
 │     ocr_pages_done++, ocr_updated_at=now      # 하트비트
 │     log_llm_usage(task_type="ocr", cost)
 │     await db.commit()                         # 매 페이지 즉시 커밋 → 손실 0
 │
 ├─ 종료 status: complete | capped(free 캡<total) | paused(예산) | error(예외)
 └─ complete/capped면 챕터 LLM 감지 (TOC/기존 챕터 없을 때만; OCR 텍스트 상단 N줄 헤더 사용)
```

`extract_text_async(db, source, start, end)` 분기 (핵심):
```
if not source.is_scanned:  return extract_text(server_path, start, end)   # 기존 동기 경로 불변
rows = SELECT ocr_page_text WHERE page in [start, end]
return "\n".join("--- Page p ---\n" + content for present pages)         # 미OCR 페이지는 누락
```

### 2.3 자동 재개 스위퍼 (`_ocr_sweeper_loop`, app startup, `ENABLE_OCR` 시)

10분 주기로:
1. 하트비트 끊긴 `running`(프로세스 사망)을 `error`로 강등: `UPDATE … WHERE ocr_status='running' AND ocr_updated_at < now-15min`.
2. 후보(`paused`·`error`) 수집 → `paused`는 예산 회복됐을 때만(`check_ocr_quota`가 False) → `_background_ocr` 재호출(원자 claim이 중복 방지). 한 사이클 최대 10권.

예산은 KST 자정에 풀리므로 앱을 안 열어도 그 주기 안에 이어받는다. 워커 2개 환경에서도 stale UPDATE의 행 잠금 + 잡의 원자 claim으로 중복은 무해. 재업로드(중복 경로)는 즉시 재개를 추가로 트리거.

### 2.4 iOS

`is_scanned=true`면 `GET /api/pdf/{id}/status`를 4초 간격 폴링. **종료 조건 = `isProcessing`(pending/running)이 아닐 때** — complete/capped/paused/error 모두에서 폴링 중단(paused 무한 폴링 방지). 배너는 상태별 문구 + 진행 중이면 결정형 프로그레스 바. 가이드 409 `ocr_incomplete`는 "아직 인식 중"/capped 업셀 문구로 처리.

---

## 3. API 계약

| Method | Path | 변경 |
|---|---|---|
| POST | `/api/pdf/upload` | 응답에 `is_scanned`/`ocr_status` 추가, 스캔감지 분기 |
| GET | `/api/pdf/{id}/status` | **신규** |
| GET | `/api/pdf/textbooks` | 응답에 `is_scanned`/`ocr_status`/`ocr_pages_done`/`ocr_pages_total` 추가(목록 칩) |
| GET | `/api/pdf/{id}/guide`, `/chapter-guide` | 쿼터 체크 + 스캔본 미완 시 409 |

### 3.2-a POST /api/pdf/upload
- Request: 기존과 동일.
- Response 200: 기존 필드 + `is_scanned: bool`, `ocr_status: "pending"|null`.
- 예시: `{ "id":"…", "totalPages":312, "is_scanned":true, "ocr_status":"pending", "indexing":"started" }`

### 3.2-b GET /api/pdf/{id}/status (신규)
```
{
  "is_scanned": bool,
  "ocr_status": "pending"|"running"|"paused"|"error"|"capped"|"complete"|null,  // 텍스트PDF는 null
  "ocr_pages_done": int,
  "ocr_pages_total": int,     // min(total_pages, ocr_cap)
  "total_pages": int,
  "capped": bool,             // ocr_status=="capped"
  "cap_limit": int|null,      // free=ocr_cap, pro=null
  "chapters_ready": bool
}
```
- 404 — textbook 없음/타 유저 소유. tier로 `cap_limit` 결정(pro면 null).

### 3.2-c GET /api/pdf/{id}/guide, /chapter-guide (변경)
- 성공 응답 동일(`PageGuideResponse`/`ChapterGuideResponse`).
- 캐시 미스 시 `check_daily_quota`(429 `quota_exceeded`) 선행.
- **409 `ocr_incomplete`**: 스캔본인데 대상 페이지/챕터가 아직 OCR 안 됨. 챕터 가이드는 **챕터 전 페이지가 OCR 완료**됐을 때만 생성(아니면 409).
  ```
  { "detail":"OCR not complete for this page/chapter", "code":"ocr_incomplete",
    "ocr_status":"running"|"paused"|"error"|"capped", "capped":bool, "page":int|null }
  ```
- 텍스트 PDF의 진짜 빈 페이지는 기존 **400 "no extractable text"** 유지(스캔본은 409로 구분).

---

## 4. 데이터 모델

**`ocr_page_text`** (`app/models/ocr.py`) — 페이지 1:1 캐시
```
id String PK | textbook_id FK(CASCADE) indexed | page Int(1-indexed)
content Text(null 바이트 제거) | created_at DateTime
UNIQUE(textbook_id, page)      # 재OCR 멱등 / 재개 skip 판정
```
전용 테이블 채택: `DocumentChunk`는 청크 단위라 페이지 1:1이 아님.

**`textbook_sources`** 컬럼 추가 (`app/models/textbook.py`)
```
is_scanned     Boolean default False
ocr_status     String  nullable   # pending|running|paused|error|capped|complete
ocr_pages_done Integer default 0
ocr_cap        Integer nullable   # 적용 캡 (free=50, pro=600, admin=total_pages)
ocr_unlimited  Boolean default F  # admin 무제한(페이지 캡·예산 우회). 마이그 e1f2a3b4c5d6
ocr_updated_at DateTime nullable  # 하트비트 → stale면 프로세스 사망 판별
```

마이그레이션: `e5f6a7b8c9d0` (테이블 1 + 컬럼 5). 배포 시 app startup CMD가 자동 적용.

---

## 5. ocr_status 상태 머신

```
        업로드(스캔본)
            │
         pending ──claim──► running ──┬──► complete            (전부 OCR)
            ▲                  │       ├──► capped              (free 캡 < total)
            │                  │       ├──► paused  (예산 초과)  ─┐
   재업로드/스위퍼 재개          │       └──► error   (예외)       │
            │                  │                                │
            └──────────────────┴──── 스위퍼: 예산 회복/재시도 ◄───┘
                               │
                  (프로세스 사망: running에서 멈춤 → 하트비트 stale →
                   스위퍼가 error로 강등 후 재개)
```

- **complete/capped/complete-text** = 종료(폴링·스위퍼 대상 아님).
- **paused** = 예산. 자정 후 스위퍼가 재개.
- **error** = 예외. 스위퍼가 재시도(상한 없음 — 영구 실패 페이지는 후속 과제).

---

## 6. 운영 (켜기 체크리스트 & 튜닝)

**켜기 전 (순서대로):**
1. `DAILY_COST_LIMIT_OCR_PRO_USD`를 **양수**로 설정. (0=무제한 → 스캔본 다수 업로드 시 순지출 폭증)
2. `ENABLE_OCR=true`.
3. (배포는 마이그레이션 자동 적용. DB에 `ocr_page_text`/컬럼 생성 확인.)

**`config.py` 파라미터:**
| 키 | 기본 | 의미 |
|---|---|---|
| `ENABLE_OCR` | `false` | 기능 토글. off면 스캔 감지 자체를 안 함(기존 흐름 불변) |
| `DAILY_COST_LIMIT_OCR_PRO_USD` | `0` | OCR(task_type=ocr) 일일 예산 버킷. 0=무제한 |
| `OCR_FREE_CAP_PAGES` | `50` | free 권당 OCR 페이지 하드 캡 |
| `OCR_MAX_PAGES_PER_BOOK` | `600` | pro 권당 백스톱(잘못된 범위 비용 캡) |
| `OCR_SCAN_TEXT_THRESHOLD` | `30` | 페이지당 평균 문자수 < 이 값이면 스캔본 |

**스위퍼 상수(`pdf.py`):** `OCR_SWEEP_INTERVAL_SEC=600`, `OCR_STALE_MINUTES=15`, `OCR_SWEEP_MAX_PER_CYCLE=10`.

---

## 7. 핵심 파일 (as-built)

| 영역 | 파일 | 내용 |
|---|---|---|
| 모델 | `app/models/ocr.py`, `app/models/textbook.py` | `OcrPageText`, 스캔/OCR 컬럼 |
| 마이그레이션 | `alembic/versions/e5f6a7b8c9d0_*.py` | 테이블+컬럼 |
| config | `app/core/config.py` | OCR 파라미터(§6) |
| OCR 서비스 | `app/services/ocr_service.py` | `render_page`, `ocr_page`(Haiku, "원문만"), `OcrResult` |
| usage 헬퍼 | `app/services/usage_service.py` | `log_llm_usage` (feedback 인라인 치환) |
| 텍스트 분기 | `app/services/pdf_service.py` | `is_scanned_pdf`, `extract_text_async`, `get_ocr_pages`, `headers_from_ocr_rows` |
| 챕터 감지 | `app/services/chapter_service.py` | `detect_chapters(server_path, headers=None)` |
| 잡·스위퍼·라우터 | `app/routers/pdf.py` | `_background_ocr`, `_ocr_sweeper_loop`, `_tier_from_cap`, upload 분기, `/status`, 가이드 409 |
| 스위퍼 기동 | `app/main.py` | startup에서 `_ocr_sweeper_loop` (ENABLE_OCR 시) |
| 쿼터 | `app/core/quota.py` | `check_ocr_quota`(task_type=ocr 별도 버킷) |
| iOS 모델 | `Models/AIResponse.swift` | `PdfStatus`, `OcrIncompleteInfo`, `TextbookListItem.ocrChip` |
| iOS API | `Services/APIClient.swift` | `getPdfStatus`, `APIError.ocrIncomplete`(409 디코드) |
| iOS UI | `Views/PdfViewerView.swift`, `CreateNoteSheet.swift`, `NoteMetaSheet.swift`, `PaywallView.swift` | 진행 배너·폴링, 목록 칩, 업로드 인디케이터, Pro 혜택 문구 |
| 테스트 | `tests/unit/test_ocr.py` | 스캔 감지, 헤더 추출, `extract_text` 불변, `_tier_from_cap`, 토글 off |

---

## 8. Risk & 완화 (as-built)

| Risk | 완화 |
|---|---|
| 무제한 쿼터로 OCR 켜면 비용 폭증 | `ENABLE_OCR` 토글 + OCR 예산 양수 강제(§6 체크리스트) |
| Haiku OCR 품질이 고전어/수식에서 미흡 | 1차는 텍스트 복원 목표. 미흡 시 Sonnet Vision 폴백(비용↑) 검토 |
| `extract_text` 시그니처 변경 영향 | 동기 `extract_text` 불변 + `extract_text_async` 래퍼로 흡수. 회귀 테스트로 텍스트PDF 경로 고정 |
| 백그라운드 잡 중복 실행(워커 2개) | 원자 claim(`UPDATE…WHERE ocr_status IN(…) RETURNING`) + `UNIQUE(textbook,page)` + skip-on-exists |
| 부분 OCR 상태로 조용히 열화된 가이드 | 미완 시 **409 명시**(침묵 금지). 챕터 가이드는 전 페이지 완료 시에만 생성. status API로 진행 노출 |
| 멈춘 잡이 영원히 안 끝남 | 3원인 분리 + 주기 스위퍼 자동 재개 + 하트비트로 프로세스 사망 감지 |
| 거대 스캔본이 pro 예산 독식 | OCR 버킷 분리 + 권당 페이지 상한 + paused/재개 |

### 후속 과제
- `error` 영구 실패 페이지의 재시도 상한/격리(현재 매 사이클 재시도).
- 스위퍼 통합 테스트(원자 claim·재개)는 DB-backed 테스트로 추가 권장(claim 분리 리팩터링 동반).
- 스캔본 RAG 인덱싱, OCR 결과 수정 UI, 노트 목록 행별 칩.
