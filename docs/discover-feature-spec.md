# 학습 자료 추천 (Discover) Spec

> **Status:** Draft
> **Date:** 2026-06-25
> **Author:** (auto-generated)

홈 화면에서 사용자가 공부하고 싶은 주제를 자연어로 입력하면, Claude의 web_search/web_fetch agentic loop로 **무료 공개 학습자료**(PDF·공개교재·강의자료)를 찾아 추천한다. 사용자의 서재(보유 교재 + ToC)를 컨텍스트로 주입해 수준을 보정하고, 백엔드가 추천 URL을 독립적으로 재검증한다.

---

## 1. Background

### 1.1 현재 상태
- 현재 교재는 **사용자가 직접 PDF를 업로드**해야만 서재에 들어온다 (`POST /api/pdf/upload`, 멀티파트). 외부 자료를 찾아 넣는 마찰이 전부 사용자 몫이다.
- 첫 실유저 후기상 페이지 가이드가 논문 읽기에 유용했고, 논문/교재가 핵심 사용 대상. "공부하고 싶은 걸 LLM에 바로 물어보고 자료를 받는" 흐름은 이 마찰을 직접 줄인다.
- Claude Vision 피드백 인프라(`feedback_service.py`)에 anthropic AsyncAnthropic 클라이언트·재시도 래퍼·usage 로깅이 이미 구축돼 있어 재사용 가능.
- `response_language`(기본 "Korean"/"English")가 `/api/feedback`·페이지 가이드에 이미 흐른다 — discover도 동일 값을 받아 추천 이유 언어/자료 언어를 맞춘다.

### 1.2 설계 합의(확정된 의사결정)
| 항목 | 결정 |
|---|---|
| 작동 위치 | **홈 화면**(노트 페이지 아님). 컨텍스트 = 사용자의 **전체 서재** |
| 플랫폼 | iPad **그리고 iPhone companion 둘 다** 지원 (`HomeView`/`PhoneHomeView` 양쪽 진입) |
| 환각 방지 | LLM이 URL을 생성하지 않고 **web_search 실결과** + **web_fetch 검증**으로만 추천 |
| 커버리지 | 큐레이션 화이트리스트 아님. 웹 전체 후보 + fetch 검증. 단 공개교육자료(OpenStax/LibreTexts/MIT OCW)·arXiv를 프롬프트로 bias |
| 수준 보정 | 서재 ToC(`chapters`, level≤2)로 학습자 프로파일 추정. **현재 수준 기본 + 한 단계 위 1개** |
| 언어 | **영어 + `response_language`**로 검색·추천. `why`는 `response_language`로 작성 |
| 검증 | 프롬프트 지시(web_fetch) + **백엔드 독립 재검증**(모델 자기보고 불신) |
| 다이제스트 입도 | 저장된 ToC를 **level≤2**(챕터+섹션)까지 |
| 인제스션 | 추천 탭 → **기기에서 다운로드 → 기존 `/api/pdf/upload` 재사용**. 백엔드 신규 인제스션 엔드포인트 없음 |

### 1.3 Out of Scope
| 항목 | 이유 |
|---|---|
| 백엔드 URL 인제스션 엔드포인트 | 클라이언트 다운로드 후 기존 멀티파트 업로드 재사용으로 대체 (Track C) |
| 저작권 합법성 100% 보장 | fetch로 무료 접근성은 거르나 라이선스 완전 판정 불가. `blocked_domains` + 프롬프트 bias가 현실적 상한 (§7) |
| Voyage 임베딩/RAG 연동 | discover는 외부 웹 검색 기반. 기존 RAG(비활성)와 무관 |
| 추천 결과 영속화/히스토리 | 1차는 stateless 응답. 저장은 후속 |

---

## 2. 현재 / 목표 플로우

```
[목표 플로우]
홈: 자연어 질의 "기초 물리학 더 깊이"
   │  (+ response_language)
   ▼
POST /api/discover  (JWT)
   │
   ├─ 서재 다이제스트 빌드: chapters JOIN textbook_sources, user_id, level≤2
   │     → "교재명 + ToC" 텍스트
   │
   ├─ Claude(sonnet-4-6) agentic loop
   │     system(전역) → 서재 다이제스트(유저 고정, 캐시) → 질의(매번)
   │     tools: web_search_20260209, web_fetch_20260209 (blocked_domains=해적사이트)
   │     while stop_reason == "pause_turn": 재전송 (server-tool loop, max_continuations)
   │     출력: 구조화 JSON {recommendations[], note}
   │
   ├─ 백엔드 재검증: 각 url을 httpx로 HEAD/GET → 죽은/비PDF/리다이렉트실패 떨굼
   │
   └─ 200 { recommendations:[{title,url,format,level,why}], note }
   ▼
홈 결과 리스트
   │  탭(PDF format)
   ▼
기기에서 url 다운로드 → 기존 POST /api/pdf/upload(멀티파트) → 서재 편입(OCR·챕터감지 파이프라인)
```

---

## 3. Backend API Inventory & Contracts

### 3.1 엔드포인트 목록

| Method | Path | 설명 | 상태 | 계약 |
|---|---|---|---|---|
| POST | `/api/discover` | 자연어 질의 → 무료 공개 자료 추천 | **신규** | §3.2-a |
| POST | `/api/pdf/upload` | 멀티파트 PDF 업로드(서재 편입) | 변경없음 | 기존 |
| GET | `/api/pdf/textbooks` | 서재 목록 | 변경없음 | 기존 |

### 3.2 신규 엔드포인트 계약 (동결)

```
### 3.2-a POST /api/discover
- Auth: Bearer JWT (get_verified_payload — tier/role 필요, quota용) — 헤더 또는 ?token=
- Quota: 호출 전 `check_daily_quota(user_id, tier, db, is_admin=role=="admin")` — **피드백/채팅과 동일한 일일 비용 한도 공유**(초과 시 429). discover의 web search/fetch usage도 `log_llm_usage`로 적재돼 같은 일일 예산에 합산
- Request body (application/json):
  {
    "query": string            (required, 1..500자, trim 후 비면 422),
    "response_language": string (optional, default "Korean")
  }
- Response 200 (application/json):
  {
    "recommendations": [
      {
        "title":  string,
        "url":    string,                         // 재검증 통과한 살아있는 URL만
        "format": "PDF" | "웹페이지" | "강의코스",
        "level":  "입문" | "학부기초" | "심화" | "대학원",
        "why":    string                          // response_language로 작성된 한 줄
      }
    ],                                            // 0..N개. 조건 미달이면 빈 배열 가능
    "note": string                                // 0개/부족 시 솔직한 한 줄. 정상이면 ""
  }
- Error:
  - 401 — JWT 검증 실패
  - 422 — query 누락/공백/길이 초과
  - 429 — 일일 쿼터 초과 (적용 시, §6.x)
  - 502 — LLM 업스트림 장애(재시도 소진) / 응답 파싱 실패 후 복구 불가
- 예시 payload (정상):
  {
    "recommendations": [
      {"title":"University Physics (OpenStax)","url":"https://openstax.org/details/books/university-physics-volume-1",
       "format":"웹페이지","level":"학부기초","why":"보유 중인 일반물리와 같은 수준의 무료 공개 교재로, 역학 전 범위를 다룹니다."},
      {"title":"MIT 8.01 Classical Mechanics","url":"https://ocw.mit.edu/courses/8-01sc-classical-mechanics-fall-2016/",
       "format":"강의코스","level":"학부기초","why":"교재 학습을 강의로 보완할 수 있는 무료 코스입니다."}
    ],
    "note": ""
  }
- 예시 payload (0개):
  { "recommendations": [], "note": "무료로 접근 가능한 합법 자료를 찾지 못했습니다. 주제를 더 구체적으로 입력해 보세요." }
- iOS: 이 계약으로 결과뷰/디코더를 선작성(Track B는 stub 응답으로 BE 완료 전 개발 가능)
```

---

## 4. 구현 설계

### 4.1 Backend — `POST /api/discover`
신규 라우터 `backend/app/routers/discover.py` (`APIRouter(prefix="/api")`), `app/main.py`에 `include_router(discover.router)` 등록.

**4.1-0 쿼터 게이트**: LLM 호출 전 `check_daily_quota(user_id, tier, db, is_admin=get_role(payload)=="admin")` (피드백 `feedback.py:78,338`과 동일 패턴). 초과 시 429. → auth는 `get_verified_payload`로 받아 `get_tier`/`get_role` 도출.

**4.1-1 서재 다이제스트 빌드** (`discover_service.build_library_digest`)
- `select(TextbookSource.id, TextbookSource.file_name)` where `user_id`.
- 각 교재의 `chapters` where `level <= 2` order by `page_start` → 트리 텍스트.
- 산출 형태(텍스트):
  ```
  - "<file_name>"
      1. <ch title>
      2. <ch title>
        2.1 <section title>
  ```
- 서재 빈 경우 → "서재 비어있음" 표기(프롬프트가 질의만으로 수준 추정).

**4.1-2 프롬프트 조립** (캐시 prefix 순서)
- system(전역 고정, `cache_control: ephemeral`): 역할·도구사용·절대규칙·검색전략·수준보정(서재기반, ①)·언어(②)·출력지시. (확정 초안은 §4.4)
- user message:
  - block1 = 서재 다이제스트 (`cache_control: ephemeral` — 유저당 고정)
  - block2 = `[자료 언어] {langs}` / `[추천 이유 언어] {response_language}` / `[질의] {query}`
  - `langs` = response_language=="English" ? "영어" : "영어, {response_language}"

**4.1-3 LLM 호출** (`discover_service.run_discovery`)
- 모델: **`claude-sonnet-4-6`** (web_search_20260209 dynamic filtering 지원 티어, 코드베이스 pricing 테이블에 존재, opus 대비 저비용 — §4.3 결정 근거).
- `feedback_service.client`(AsyncAnthropic, max_retries=0) + `create_message_with_retry` 재사용.
- tools: `[{"type":"web_search_20260209","name":"web_search","blocked_domains":[...해적사이트...]}, {"type":"web_fetch_20260209","name":"web_fetch"}]`
- server-tool loop: `while resp.stop_reason == "pause_turn"` → messages에 assistant content append 후 재호출, `max_continuations=5` 가드.
- 구조화 출력: anthropic 0.94.0 지원 시 `output_config={"format":{"type":"json_schema","schema": DISCOVER_SCHEMA}}`; 미지원 시 system에 "오직 JSON만 출력" 지시 + 방어적 파싱(코드펜스 제거 후 첫 `{...}` 추출). (§6.x 확인 필요)
- usage 로깅: 기존 `log_llm_usage` 재사용(모델·토큰).

**4.1-4 백엔드 재검증** (`discover_service.verify_urls`)
- 각 recommendation.url을 `httpx.AsyncClient`(timeout~5s, follow_redirects=True)로 검사.
  - PDF format: `HEAD`(실패 시 `GET` range) → 200/3xx 도달 + content-type/url에 pdf 신호.
  - 웹페이지/강의코스: 200 도달이면 통과.
- 병렬(`asyncio.gather`) + 개별 예외 격리. 실패한 url은 결과에서 제외.
- 전수 탈락 시 recommendations=[] + note 보존/대체.

### 4.2 iOS — 홈 진입 + 결과 + 인제스션

**진입점(확정): 그리드 상단 컴팩트 프롬프트 바.**
- 노트 `LazyVGrid` **바로 위**에 한 줄짜리 검색창형 pill: 리딩 아이콘(✦/나침반) + placeholder "공부할 자료 찾기…". 일러스트·부제목 없음(히어로 카드의 산만함 회피), 아이콘 버튼보다 행동 유도 명확(placeholder가 곧 CTA).
- **기존 `.searchable`(노트 필터링, prompt "제목·과목·교재로 검색")와 명확히 구분** — 위치(그리드 상단 vs 내비), 아이콘, placeholder 문구로 분리. 같은 입력창 공유 금지(두 검색 성격이 다름).
- 탭 → discover 시트 오픈(질의 입력 = 시트 안 TextField). 상단 바는 표시/진입 전용.

**플로우**: 시트 TextField 입력 → `APIClient.discover(query:responseLanguage:)` → `DiscoverResultsView`(공용)에 결과 리스트. 각 항목: title / level chip / source·format / why / 액션(PDF→"서재에 추가", 웹·코스→"열기"). 0개면 `note` 중앙 표시. `DiscoverResult`/`DiscoverItem` Decodable 신규.

**플랫폼**: 프롬프트 바·결과뷰 모두 iPad(`HomeView`)/iPhone(`PhoneHomeView`) 공용 컴포넌트. iPhone는 좁은 폭·full-height 시트, iPad는 form 시트. 한 줄 바라 양쪽 레이아웃에 잘 맞음.
- **Track C 인제스션**: PDF format 항목 탭 → `url` 다운로드(URLSession) → 기존 멀티파트 업로드(`APIClient.uploadFile`/업로드 경로 재사용) → 서재 갱신. 웹페이지/강의코스 format은 외부 브라우저(SafariView) 오픈(인제스션 아님).

### 4.3 모델 선택 근거 (설계 조정)
대화 중 초안은 `claude-opus-4-8`였으나, 구현 시 **`claude-sonnet-4-6`로 조정**:
- web_search_20260209/web_fetch_20260209 dynamic filtering은 Opus 4.6+/**Sonnet 4.6**에서 지원 → Sonnet 4.6 자격 충족.
- 코드베이스 운영 표준이 sonnet-4-6(pricing 테이블·feedback 경로)이라 비용·일관성 우위.
- 품질 부족이 관측되면 opus-4-8로 승격은 설정 한 줄.

### 4.4 시스템 프롬프트 (확정 초안)
대화에서 확정한 전문(역할/도구/절대규칙/검색전략/수준보정·서재기반/언어/출력)을 `discover_service.SYSTEM_PROMPT` 상수로 둔다. 출력 스키마는 §3.2-a의 recommendations/note 구조와 일치.

---

## 5. 구현 단계 (Tracks)

```
                ┌─── Track A: Backend /api/discover (단일 영역, 내부 순차)
시작 ──[계약 §3.2-a 동결]──┤
                ├─── Track B: iOS 홈 진입+입력+결과뷰 (계약으로 stub 선개발)
                │
                └─── Track C: iOS 인제스션 (탭→다운로드→기존 업로드)
```

**트랙 간 의존성:**
- 계약 §3.2-a는 **동결됨** → B/C는 BE 완료 전 stub로 병렬 개발 가능.
- C는 B의 결과뷰(탭 액션)에 의존 → **B-결과뷰 완료 후 C 시작**. (둘 다 iOS라 같은 인원이면 순차)
- A·B의 **통합** 검증은 A 완료 필요(실 BE 응답).

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A → B → C 순차 |
| 2명 | P1=A, P2=B(stub)→C |
| 3명 | P1=A, P2=B, P3=C(B 결과뷰 인터페이스 합의 후) |

### Track A: Backend `/api/discover`
**의존:** 없음
**내부 순서:** A-1 → A-2 → A-3 → A-4 (A-2 다이제스트는 A-3 LLM과 독립이라 일부 병렬 가능)
**작업량:** 중간. 가장 복잡한 부분 = A-3 server-tool agentic loop(pause_turn 처리) + 구조화 출력 파싱 분기.

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/routers/discover.py` (신규), `backend/app/main.py` | 라우터·요청 모델(`DiscoverRequest`)·응답 모델·auth(`get_verified_payload`)·`check_daily_quota` 게이트·`include_router` |
| A-2 | `backend/app/services/discover_service.py` (신규) | `build_library_digest(db, user_id)` — chapters JOIN, level≤2 트리 텍스트 |
| A-3 | `backend/app/services/discover_service.py` | `SYSTEM_PROMPT`, 프롬프트 조립(캐시 breakpoint), `run_discovery()` — 모델·web tools·pause_turn 루프·구조화/방어적 파싱, usage 로깅 |
| A-4 | `backend/app/services/discover_service.py` | `verify_urls()` — httpx 병렬 재검증, 탈락 제거 |
| A-5 | `backend/tests/test_discover.py` (신규) | 다이제스트 빌드·파싱·재검증 단위테스트(LLM/HTTP는 mock). 회귀 가드 |

### Track B: iOS 홈 진입 + 입력 + 결과뷰
**의존:** 계약 §3.2-a (동결됨) → stub로 선개발
**내부 순서:** B-1 모델/APIClient → B-2 진입·입력 → B-3 결과뷰
**작업량:** 중간.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `ios-app/ScatchLM/Services/APIClient.swift`, `ios-app/ScatchLM/Models/DiscoverResult.swift`(신규) | `discover(query:responseLanguage:)` async 메서드, `DiscoverResult`/`DiscoverItem` Decodable(format/level enum) |
| B-2 | `ios-app/ScatchLM/Views/HomeView.swift` (iPad), `PhoneHomeView.swift` (iPhone), `DiscoverPromptBar.swift`(신규 공용) | **그리드 상단 컴팩트 프롬프트 바**(한 줄 pill, 기존 `.searchable`과 분리) → 탭 시 discover 시트. 시트 내 질의 입력 + 로딩 상태. iPhone full-height / iPad form 시트 |
| B-3 | `ios-app/ScatchLM/Views/DiscoverResultsView.swift`(신규) | **iPad/iPhone 공용** 결과 리스트(title/level chip/format/why), 빈/note 상태, 항목 탭 액션 위임 |

### Track C: iOS 인제스션 (탭 → 다운로드 → 기존 업로드)
**의존:** Track B-3 결과뷰(탭 액션) + 기존 업로드 경로(존재)
**내부 순서:** C-1 → C-2
**작업량:** 작음~중간. 가장 복잡 = 대용량 PDF 다운로드 진행/실패 처리.

| ID | 파일 | 내용 |
|---|---|---|
| C-1 | `ios-app/ScatchLM/Services/...`(다운로드 헬퍼) | url → 임시파일 다운로드(URLSession), 진행/취소/에러 |
| C-2 | `DiscoverResultsView.swift` / 업로드 호출부 | PDF format 탭 → 다운로드 → 기존 멀티파트 업로드 재사용 → 서재 갱신. 웹/코스 format → SafariView 오픈. **공용 결과뷰라 iPad/iPhone 동일 동작** |

> **빌드 검증(CLAUDE.md §빌드 정책):** iOS 변경은 iPad 실기기 + 시뮬레이터에 더해 **iPhone companion 타깃 빌드**까지 컴파일 검증. 실기기 동작 확인 전 "완료" 선언 금지.

---

## 6. 확인 완료 사항 (코드 검증)

- **Anthropic 클라이언트·재시도·모델**: `backend/app/services/feedback_service.py:80` `client = anthropic.AsyncAnthropic(api_key=..., max_retries=0)`, `:46` `create_message_with_retry(client, **kwargs)`, pricing 테이블에 `claude-sonnet-4-6`(`:197`) 존재. → 재사용 확정.
- **인증/세션 DI**: `backend/app/core/auth.py:110` `get_current_user_id(...)`, 라우터 패턴 `user_id=Depends(get_current_user_id)`, `db=Depends(get_db)` (`backend/app/routers/pdf.py:448-450`). → 그대로 사용.
- **서재 다이제스트 소스**: `backend/app/models/chapter.py` `Chapter(textbook_id, level[1=chapter,2=section], title, page_start, page_end)`, `backend/app/models/textbook.py` `TextbookSource(id, user_id, file_name, total_pages, ...)`. **title 전용 컬럼 없음 → `file_name`을 교재명으로 사용. language 컬럼 없음 → 자료 언어는 `response_language`로만 결정**.
- **라우터 prefix**: feedback `/api`(`feedback.py:46`), pdf `/api/pdf`(`pdf.py:45`). → discover는 `/api`(=`/api/discover`).
- **response_language 흐름**: `feedback.py` `response_language: str = Form("English")`, `guide` 모델 캐시키. → discover 동일 파라미터 수용.
- **의존성**: anthropic `0.94.0`, httpx `0.28.1`, aiohttp `3.13.5` 설치 확인(venv). → 재검증은 httpx.
- **iOS 홈/업로드 헬퍼**: `ios-app/ScatchLM/Views/HomeView.swift`·`PhoneHomeView.swift` 존재, `APIClient.swift:189` `uploadFile<T: Decodable>` 멀티파트 헬퍼 존재. → 진입점·인제스션 재사용 가능.
- **백엔드 URL 인제스션 부재**: `pdf_service.save_pdf(file: UploadFile, ...)`만 존재(URL 다운로드 경로 없음). → 클라이언트 다운로드+기존 업로드로 우회(Out of Scope 1.3).

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | anthropic 0.94.0가 `output_config={"format":{"type":"json_schema",...}}`를 messages.create에서 수용하는가 | `python -c "import inspect, anthropic; ..."` 또는 시험 호출. 미지원이면 A-3 방어적 JSON 파싱 분기 |
| 2 | 0.94.0가 tool type `web_search_20260209`/`web_fetch_20260209`를 인식하는가(아니면 구버전 `web_search_20250305` 등) | SDK 타입/시험 호출. 구버전만 지원 시 tool type·dynamic filtering 가용성 재평가 |
| 3 | `blocked_domains` 해적사이트 목록 출처/유지 | 초기 소규모 하드코딩 + 운영 중 보강. 별도 결정 |

> **확정(2026-06-25):** 일일 쿼터는 채팅/피드백과 **동일 정책 공유** — `check_daily_quota` 게이트 + `log_llm_usage` 합산(§4.1-0, §3.2-a). 별도 결정 종료.

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 추천 URL이 죽었거나 페이월/해적 | 기능 신뢰 붕괴(두 번째 사용 안 함) | web_fetch 검증 + **백엔드 독립 재검증**(A-4) + `blocked_domains` + 프롬프트 무료·합법 절대규칙 |
| 저작권 합법성 완전 판정 불가 | 잠재적 법적/심사 리스크 | 무료 접근성만 보장, 공식·공개 라이선스 출처 bias, 의심 시 제외. 100% 보장 아님 명시(§1.3) |
| LLM이 fetch 없이 URL 환각 | 죽은 링크 추천 | system 절대규칙 + A-4 재검증이 최종 안전장치(모델 자기보고 불신) |
| web search/fetch 비용·지연 | 응답 느림·비용 증가 | 후보 소수(3~5)로 제한, dynamic filtering, max_continuations 가드, 쿼터(6.x-3) |
| anthropic 0.94.0 신 tool/output 미지원 | 구현 형태 변경 | §6.x-1,2 선확인 → 미지원 시 방어적 파싱/구버전 tool로 폴백 |
| pause_turn 무한 루프 | 행 | `max_continuations=5` 가드 + 502 폴백 |
| 대용량 PDF 다운로드 실패(C) | 인제스션 실패 | 진행/취소/타임아웃·에러 UI, 실패 시 SafariView 폴백 |
| iPhone companion 레이아웃 깨짐/미동작 | companion 사용자 기능 못 씀 | 결과뷰 공용화 + 진입 UI 플랫폼별 분기, iPhone 타깃 빌드·실기기 검증 필수 |
