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
- **tier 정책** (`get_tier` → normal/pro) — **2026-06 개정**: "한 PDF는 원자적으로 처리"가 원칙. 비용을
  *시간축*으로 평탄화(일일 예산 → 며칠에 걸쳐 처리)하던 옛 모델은 UX가 나빠 폐기했다. 게이트는 두 지점:
  - **per-file 페이지 천장**(`OCR_MAX_PAGES_PER_FILE`, 기본 200p): 스캔본이 이 페이지 수를 넘으면
    **업로드 자체를 거부(422 `scanned_page_limit_exceeded`)** — free·pro 공통. 텍스트 레이어 PDF는
    OCR이 불필요하므로 페이지 제한·쿼터 모두 없음(무제한).
  - **월 건수 쿼터**: OCR을 *시작한* 스캔본 파일 수를 **KST 달력 월** 단위로 제한.
    free `OCR_MONTHLY_FILES_FREE`(기본 2), pro `OCR_MONTHLY_FILES_PRO`(기본 5).
    `start_ocr` 진입 시 검사(초과 → 429 `ocr_quota_exceeded`). `ocr_started_at`(최초 1회 set)으로
    그 달의 건수를 세며, 재개/재시도는 이미 슬롯을 차지했으므로 재카운트하지 않는다.
  - **per-tier 페이지 캡·`capped` 상태는 폐지**. 모든 스캔본은 ≤천장이므로 시작했으면 끝까지 처리
    (`complete`). `ocr_cap`은 `min(total, 천장)` 클램프(레거시 >천장 행 방어)로만 남는다.
  - **admin**(JWT `role=admin`): **무제한** — 월 건수·페이지 천장 우회. `ocr_unlimited=true` 영속화.
- **비용 상한**: 월 건수 × per-file 천장이 곧 유저당 월 비용 상한이라 일일 예산 버킷은 불필요.
  `DAILY_COST_LIMIT_OCR_PRO_USD`는 무한재시도 등 폭주 버그 대비 *높은 백스톱*으로만 남는다(정상 경로 미도달).
- **비용/쿼터**: OCR도 Claude 호출 → `LLMUsage(task_type="ocr")`로 비용 기록.
- **자동 재개**: 잡이 멈추는 원인(비용 백스톱/예외/프로세스 사망)을 구분하고, 인프로세스 주기 스위퍼가 자동 재개(§2.3). cron 등 외부 인프라 불필요.

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

**평가는 교재 생성(upload) 1회.** is_scanned는 파일 고유 속성(텍스트 레이어 유무)이므로 ENABLE_OCR과 무관하게 upload에서 무조건 계산해 박제한다. 이후 재사용·노트첨부는 이 값을 그대로 읽는다(재평가 없음 — 이게 "단일 평가 지점"). tier 의존 예산(캡/무제한)은 평가가 아니라 **시작 시점(start_ocr)** 에 결정한다.

```
POST /api/pdf/upload  (get_verified_payload → user_id, tier)
  │
  ├─ save_pdf → total_pages, content_hash
  ├─ 중복(content_hash) → 기존 레코드 재사용(is_scanned 이미 박제됨 → 재평가 불필요).
  │     스캔본이 이미-시작됨(pending/paused/error)이면 즉시 재개. available(미시작)은 재개 안 함.
  │
  ├─ is_scanned = has_no_text_layer()   # ENABLE_OCR 무관, 항상 평가. 파일 속성(이진 사실).
  │     중앙부 최대 10p 샘플의 추출 텍스트가 전부 공백 → True. 퍼지 임계값 아님.
  │
  ├─ extract_toc(bookmarks) 있으면 챕터 저장 (스캔본도 임베디드 TOC면 동작)
  │
  ├─ TextbookSource(is_scanned, ocr_status = available if (is_scanned && ENABLE_OCR) else null) 저장
  │     ocr_cap/ocr_unlimited는 여기서 안 정함(start_ocr에서 tier로 결정).
  │
  ├─ is_scanned=false → (TOC 없으면) _background_detect_chapters. _background_index는 항상.
  │
  └─ 응답: { ..., is_scanned, ocr_status }
        ↓
  [재사용/노트첨부로 열 때] GET /api/pdf/{id}/status
        is_scanned & ENABLE_OCR & ocr_status==null → "available" 파생(싼 DB write 1회, PDF 재오픈 X)
        ↓
  POST /api/pdf/{id}/ocr/start  (유저가 쿼터 소진 동의)
        ocr_cap/ocr_unlimited를 현재 tier로 결정 → ocr_status: available → pending → _background_ocr 등록
        챕터 LLM 감지는 OCR 완료 후로 연기(텍스트 레이어가 비어 있으므로)
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
 │     try: img = render_page(doc, page-1)      # 렌더 실패(손상 페이지) → 빈 페이지 박제+continue
 │     res  = await ocr_page(img)               # Haiku "원문만". 400(콘텐츠필터)=blocked
 │     INSERT ocr_page_text(page, content)       # blocked면 빈 문자열(그 페이지만 누락, 잡은 완주)
 │     ocr_pages_done++, ocr_updated_at=now      # 하트비트
 │     if not blocked: log_llm_usage(task_type="ocr", cost)   # 차단된 요청은 비용 0 → 미기록
 │     await db.commit()                         # 매 페이지 즉시 커밋 → 손실 0
 │
 │  ※ 페이지 단위 격리: 비재시도성 400(콘텐츠 필터/잘못된 이미지)·렌더 실패는 그 페이지만 빈 칸으로
 │    건너뛰고 잡은 계속. 한 페이지가 잡 전체를 죽이거나 스위퍼 무한 재시도를 유발하지 않게 함.
 │    일시 오류(연결/타임아웃/429/5xx)는 전파 → status="error" → 스위퍼가 재개(캐시 skip).
 │
 ├─ 종료 status: complete | capped(free 캡<total) | paused(예산) | error(일시 예외). blocked 페이지 수 로깅
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

`is_scanned=true`면 `GET /api/pdf/{id}/status`를 4초 간격 폴링. **종료 조건 = `isProcessing`(pending/running/paused)이 아닐 때** — available/complete/capped/error에서 폴링 중단. 배너:
- **`available`**: "텍스트가 인식되지 않는 교재예요" + **[이미지 인식 시작]** 버튼 → 탭 시 **쿼터 소진 알럿**(`"…AI 사용량(쿼터)을 소진합니다"`) → 확인 시 `POST /{id}/ocr/start` → pending → 폴링 재개. **자동 시작 없음 — 명시적 동의가 유일한 트리거.**
- pending/running: 진행률 + 결정형 프로그레스 바. paused/error/capped: 상태 문구(capped는 Pro 업셀).

가이드 409 `ocr_incomplete`는 "아직 인식 중"/capped 업셀 문구로 처리.

### 2.5 평가/예산/표시의 분리 (stale-PDF 근본 해결)

**문제(로그로 확인):** 노트에 PDF가 붙는 경로는 둘인데 백엔드 평가는 하나뿐이었다 — 새 파일 피커만 `/pdf/upload`를 타고, **기존 교재 선택(`NoteMetaSheet`의 `textbookId` 로컬 대입)은 백엔드 호출 0.** 게다가 평가가 `ENABLE_OCR`로 게이팅돼 있어, OCR 켜기 전 올라간 스캔본은 `is_scanned=false`로 굳었다. content_hash dedup이 재업로드까지 흡수하니 **노트북을 새로 만들어도 같은 stale 교재 레코드를 공유** → OCR이 영영 안 떴다.

**근본 재구성 — 세 관심사를 분리하고, "재오픈"의 정의를 명확히(A=intake vs B=open):**

| 관심사 | 시점 | PDF 파일 열기 |
|---|---|---|
| **평가** `is_scanned` (파일 속성, 텍스트레이어 유무) | upload + **intake(A, ensure)** | ✓ — 단 **마커로 textbook당 평생 1회** |
| **표시** `ocr_status="available"` 파생 | `GET /status` 읽기(B) / ensure | ✗ — 싼 boolean |
| **예산** `ocr_cap`/`ocr_unlimited` (tier 의존) | `start_ocr` 시점 현재 tier로 | ✗ |

- **A(기존 PDF로 새 노트 생성 = intake)** 에서 재평가한다 — `POST /{id}/ensure`. `scan_evaluated=false`면 `has_no_text_layer` 1회 → `is_scanned` 갱신 + 마커 set. **마커가 파일 재오픈을 textbook당 평생 1회로 바운드**(같은 PDF로 노트 N개 만들어도 1번, 텍스트 PDF도 1번). → 수동 백필 불필요한 **자가 치유**.
- **B(이미 만든 노트 열기/status 폴링)** 는 재평가(파일 재오픈) 안 함 — 순수 읽기. `ocr_status` available 파생(싼 boolean)만. "열 때마다 검사" 우려가 구조적으로 0.
- 신규 업로드는 upload에서 무조건 평가 + `scan_evaluated=true` → intake 재평가 면제(ensure는 멱등 no-op).
- iOS: `CreateNoteSheet`(만들기)·`NoteMetaSheet`(저장)에서 교재 첨부 시 `ensureTextbook(id)` 호출(fire-and-forget). 노트 저장→열기 간극이 ensure 지연을 흡수.

**레거시:** 게이팅 시절 `is_scanned=false`로 굳은 기존 레코드는 다음 intake(새 노트에 편입)에서 1회 자가 치유. 마이그레이션이 `is_scanned=true` 행만 `scan_evaluated=true`로 면제하고 `false` 행은 미평가로 남겨 재평가 대상화. **수동 백필 스크립트 없음.**

---

## 3. API 계약

| Method | Path | 변경 |
|---|---|---|
| POST | `/api/pdf/upload` | 응답에 `is_scanned`/`ocr_status` 추가, 텍스트레이어 이진 감지(자동시작 X) |
| GET | `/api/pdf/{id}/status` | **신규** — 순수 읽기(B). is_scanned 재평가 안 함 |
| POST | `/api/pdf/{id}/ensure` | **신규** — intake(A) 1회 재평가(자가 치유). 멱등 |
| POST | `/api/pdf/{id}/ocr/start` | **신규** — 명시적 OCR 시작(쿼터 동의) |
| GET | `/api/pdf/textbooks` | 응답에 `is_scanned`/`ocr_status`/`ocr_pages_done`/`ocr_pages_total` 추가(목록 칩) |
| GET | `/api/pdf/{id}/guide`, `/chapter-guide` | 쿼터 체크 + 스캔본 미완 시 409 |

### 3.2-a POST /api/pdf/upload
- Request: 기존과 동일.
- Response 200: 기존 필드 + `is_scanned: bool`(ENABLE_OCR 무관, 파일 속성), `ocr_status: "available"|null`(= is_scanned && ENABLE_OCR).
- 예시(OCR on): `{ "id":"…", "is_scanned":true, "ocr_status":"available", "indexing":"started" }`
- 예시(OCR off지만 스캔본): `{ "is_scanned":true, "ocr_status":null }` — 평가는 됐고, ENABLE_OCR 켜지면 status가 available 파생.
- OCR 자동 시작 안 함. 시작은 §3.2-d.

### 3.2-e POST /api/pdf/{id}/ensure (신규)
- Request: path `id`. body 없음. iOS가 노트 생성/저장 시 교재 첨부(intake, A)에서 호출.
- 동작: `scan_evaluated=false`면 `has_no_text_layer`로 `is_scanned` 1회 재평가 + 마커 set(파일 재오픈 평생 1회). 이후 `ocr_status` available 파생. **멱등** — 이미 평가됐으면 파일 안 엶.
- Response 200: `PdfStatusResponse`(§3.2-b).
- Error: 404 textbook 없음/타 유저.

### 3.2-d POST /api/pdf/{id}/ocr/start (신규)
- Request: path `id`. body 없음. 유저가 쿼터 소진에 명시적 동의했음을 의미.
- 동작: 현재 tier로 `ocr_cap`/`ocr_unlimited` 결정(예산은 시작 시점에) → `ocr_status` null/available/paused/error → pending 전이 + `_background_ocr` 등록. running/pending/complete/capped는 멱등 무동작.
- Response 200: `PdfStatusResponse`(§3.2-b)와 동일 — 시작 후 현재 상태.
- Error: 404 textbook 없음/타 유저, 400 텍스트 PDF(`is_scanned=false`)에 호출.

### 3.2-b GET /api/pdf/{id}/status (신규)
```
{
  "is_scanned": bool,
  "ocr_status": "available"|"pending"|"running"|"paused"|"error"|"capped"|"complete"|null,  // 텍스트PDF는 null
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
is_scanned     Boolean default False  # 파일 속성. upload에서 ENABLE_OCR 무관 무조건 평가
ocr_status     String  nullable   # null|available|pending|running|paused|error|capped|complete
ocr_pages_done Integer default 0
ocr_cap        Integer nullable   # start_ocr에서 설정 (free=50, pro=600, admin=total_pages). 그 전엔 null
ocr_unlimited  Boolean default F  # start_ocr에서 admin 판정 설정(페이지 캡·예산 우회). 마이그 e1f2a3b4c5d6
scan_evaluated Boolean default F  # "현재 규칙으로 is_scanned 평가했나" 마커. upload=true, intake(ensure)
                                  #   가 false면 1회 재평가 후 set → 파일 재오픈 평생 1회. 마이그 f2a3b4c5d6e7
                                  #   (마이그: is_scanned=true 행은 true로 면제, false 행만 false 유지)
ocr_updated_at DateTime nullable  # 하트비트 → stale면 프로세스 사망 판별
```

마이그레이션: `e5f6a7b8c9d0` (테이블 1 + 컬럼 5). 배포 시 app startup CMD가 자동 적용.

---

## 5. ocr_status 상태 머신

```
        업로드(스캔본, 텍스트레이어 없음)
            │
        available ──[유저 명시적 start + 쿼터 동의]──┐   (자동 시작 없음)
            │                                       ▼
         pending ──claim──► running ──┬──► complete            (전부 OCR)
            ▲                  │       ├──► capped              (free 캡 < total)
            │                  │       ├──► paused  (예산 초과)  ─┐
   재업로드/스위퍼 재개          │       └──► error   (예외)       │
            │                  │                                │
            └──────────────────┴──── 스위퍼: 예산 회복/재시도 ◄───┘
   (available은 스위퍼·재업로드가 자동 시작하지 않음 — 유저 start만 트리거)
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

스캔 감지는 임계값 없이 **텍스트 레이어 유무(이진)** — `has_no_text_layer()`. 감지는 OCR을 자동 시작하지 않고 iOS에 시작 버튼을 제안할지만 결정.

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
