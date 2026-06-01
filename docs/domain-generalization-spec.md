# 서비스 범용화 Spec: 외국어 학습 → 임의 학습 분야

> **Status:** ✅ 1차 구현 완료 (2026-06-01)
> **Date:** 2026-06-01
> **Author:** (auto-generated)
>
> **구현 결과:** Track A(BE 프롬프트 5곳 P1~P7) + Track B(iOS UI U1~U4, 채팅 subject 전송 B-4) 모두 반영.
> iOS 시뮬레이터 빌드 성공, 백엔드 전체 테스트 46 passed(`test_feedback_prompt` 분야 범용화 회귀 테스트 추가 포함).
> 미검증 잔여: §7의 "쿼리 리라이트 강제 영어번역 제거"가 기존 언어학습 RAG 검색에 미치는 영향 — 실교재 회귀 필요(자동 테스트로 커버 불가).

---

## 1. Background

### 1.1 현재 상태
ScatchLM은 "펜 드로잉 기반 **외국어 학습** 보조 앱"으로 출발했고, LLM 프롬프트 전반에 "foreign language learning", "translation", "grammar/vocab" 같은 언어 학습 전제가 하드코딩되어 있다. 그러나:

- 노트는 `language`(자유 텍스트) 하나로만 분야를 구분하며, 백엔드/iOS 어디에도 `language` 값으로 **분기하는 로직이 없다** — 오로지 LLM 프롬프트 문자열에 주입되거나 화면에 표시될 뿐이다.
- 사용자는 이미 `language` 입력칸(placeholder "e.g. Japanese, Ancient Greek")에 임의 문자열을 입력할 수 있다. 즉 데이터 경로는 분야 확장에 이미 열려 있고, **LLM 프롬프트의 언어학습 전제와 iOS UI 라벨만 분야 중립적으로 바꾸면** 물리/역사/수학 등 임의 분야로 확장된다.

이 작업의 본질은 **신규 기능이 아니라 "언어학습 하드코딩 제거 + 분야 변수화"**다. API 계약·DB 스키마 변경이 없어 ROI가 높다.

### 1.2 합의된 핵심 결정
- **데이터 모델 무변경(재활용):** 기존 `language` 필드(`Note`/`AIResponse`/`LLMUsage`, iOS `Note`)를 "학습 분야(subject/domain)"로 **의미만 확장**한다. 컬럼명·파라미터명 유지, 마이그레이션 없음.
- **`response_language`는 별도 유지:** 응답 언어 축은 그대로. 분야 축(`language`)과 직교한다. (예: 분야="물리학", 응답언어="Korean")
- **분기 없는 적응형 프롬프트:** 코드에서 `if subject == "언어"` 식 분기를 만들지 않는다. 분야 값을 프롬프트에 주입하고, "언어 학습이면 번역/문법까지 검토, 아니면 개념 정확성 위주" 같은 **조건부 지시를 프롬프트 안에서** LLM이 판단하게 한다.

### 1.3 Out of Scope
| 항목 | 이유 |
|---|---|
| `language` → `subject` 컬럼/파라미터 **리네이밍** | 합의상 의미만 재활용. 리네이밍은 BE+iOS 동시 마이그레이션 필요 → 별도 phase |
| `subject`/`domain` **신규 필드 추가** | 위와 동일. 현 단계는 무마이그레이션 원칙 |
| 분야별 모델 라우팅·분야 메타데이터 추적(LLMUsage 분야 통계) | 분기 로직 도입은 별도 작업. 현재는 `language` 문자열 그대로 적재됨 |
| 교재(PDF) 인덱싱·임베딩 파이프라인 변경 | 분야 무관하게 동작(텍스트 청크 임베딩). 프롬프트만 영향 |
| iOS `language` 기본값 `"en"` 의 코드값 정리 | §4.4에서 표시 처리만. 데이터 정리는 불필요 |

### 1.4 기존 코드 정리 대상
하드코딩된 언어학습 전제 문자열 (아래 §3에서 위치 명시). dead code 아님 — 동작하는 프롬프트를 분야 중립으로 교체하는 것.

---

## 2. 현재 플로우

```
[iOS] CreateNoteSheet
  Title / "Target Language"(자유텍스트) / Textbook(optional)
        │ onCreate(title, language, textbook)
        ▼
  Note.language ("en" 기본) ──저장──▶ GRDB
        │
        │ 피드백 요청 시 (NoteView.swift:758)
        ▼
[BE] POST /api/feedback   form: language, response_language, ...
        │
        ├─ feedback_service.get_feedback(language, response_language, ...)
        │     system = _build_system_prompt(response_language)   ← "foreign language learning assistant" 하드코딩
        │     user   = f"Language: {language}. Respond in {response_language}. ..."  ← language는 여기만
        │
        ├─ POST /api/feedback/chat   → system: "language learning tutor ..." 하드코딩
        │
        ├─ GET /api/pdf/{id}/guide        → _page_guide_prompt  "English textbook" 하드코딩
        ├─ GET /api/pdf/{id}/chapter-guide → _chapter_guide_prompt  "grammar/vocab" 하드코딩
        │
        └─ chat RAG → retrieval_service.rewrite_query_for_search  "language learning textbook" / "Translate to English" 하드코딩
```

**관찰:** `language` 값이 실제로 LLM에 전달되는 경로는 `feedback_service.py:125`(유저 프롬프트) 와 `get_recognition`(필기 인식, `:85`) 뿐. 채팅/가이드/쿼리리라이트는 `language` 값조차 받지 않고 시스템 프롬프트에 학습분야가 "언어"라고 **고정 가정**한다.

---

## 3. 변경 대상 인벤토리 (프롬프트 5곳 + iOS UI 4곳)

> **API 계약 변경 없음.** 모든 엔드포인트의 request/response 스키마 그대로. `language` 파라미터의 *의미*만 "대상 언어"→"학습 분야"로 확장. 따라서 BE/iOS 트랙 간 계약 동결 불필요 — 진짜 병렬.

### 3.1 Backend 프롬프트

| # | 파일:라인 | 현재 하드코딩 | 변경 방향 |
|---|---|---|---|
| P1 | `backend/app/services/feedback_service.py:15-38` (`_build_system_prompt`) | "You are a foreign language learning assistant", "Check translations for accuracy" | 분야 중립 study assistant + "언어 학습일 경우에만 번역/문법 검토" 조건부 지시. `subject` 인자 추가 주입 |
| P2 | `backend/app/services/feedback_service.py:125` (유저 프롬프트) | `f"Language: {language}. ..."` | `f"Subject: {language}. ..."` (변수 그대로, 라벨만) |
| P3 | `backend/app/services/feedback_service.py:85` (`get_recognition`) | `f"Language: {language}. Read the handwriting..."` | `f"Subject: {language}. Read the handwriting..."` — 인식은 분야 무관하므로 라벨만 |
| P4 | `backend/app/routers/feedback.py:316-318` (chat system) | "You are a language learning tutor helping a student study with their textbook." | 분야 중립 tutor. `language`(=분야) 값을 chat 요청에서 받아 주입 (※ ChatRequest에 분야 전달 필요 — §4.2 참고) |
| P5 | `backend/app/services/guide_service.py:13-19` (`_page_guide_prompt`) | "non-English speaker understand an **English** textbook", "Translate key terms" | "학습자가 {response_language}로 교재 페이지를 이해하도록 설명. 원문 언어가 다르면 핵심 용어 번역" — 분야·언어 중립 |
| P6 | `backend/app/services/guide_service.py:45-55` (`_chapter_guide_prompt`) | "language learning tutor", JSON 키 설명 "grammar/vocab", "errors learners make" | "study tutor", `key_concepts`="핵심 개념/용어/기술", `common_mistakes`="흔한 오해/실수" — JSON 키명은 유지(스키마 호환), 설명문만 중립화 |
| P7 | `backend/app/services/retrieval_service.py:39-45` (쿼리 리라이트) | "language learning textbook", "Translate to English if needed" | "a textbook" / 강제 영어번역 제거 (§7 Risk 참조). 검색 쿼리는 원문 언어 유지 |

### 3.2 iOS UI

| # | 파일:라인 | 현재 | 변경 방향 |
|---|---|---|---|
| U1 | `ios-app/ScatchLM/Views/CreateNoteSheet.swift:24-25` | `Section("Target Language")`, placeholder "e.g. Japanese, Ancient Greek" | `Section("Subject")`(또는 "분야"), placeholder "e.g. Japanese, Physics, World History" |
| U2 | `ios-app/ScatchLM/Views/CreateNoteSheet.swift:121` (`loadRecentLanguages`) | 함수/변수명 `recentLanguages` | 동작 동일, 라벨링만(이름 변경은 선택). 최근 분야 빠른선택 그대로 |
| U3 | `ios-app/ScatchLM/Views/EditNoteSheet.swift:24-27` | "Target Language" + 동일 placeholder | U1과 동일하게 통일 |
| U4 | `ios-app/ScatchLM/Views/HomeView.swift:170` | `Text(note.language.uppercased())` 배지 | 분야명이 한글일 수 있음 → `.uppercased()` 제거 또는 영문일 때만 대문자. (한글엔 무영향이나 "물리학"→그대로) |

> `Note.swift:47` 기본값 `"en"`, `DatabaseService.swift:33` 컬럼 기본값 `"en"` 은 **유지**. 빈 입력 시 fallback일 뿐이며 의미 충돌 없음(§4.4).

---

## 4. 설계

### 4.1 적응형 시스템 프롬프트 (P1 — 핵심 설계 난제)
분기 없이 단일 프롬프트가 "Japanese"와 "물리학"을 모두 커버해야 한다. `subject` 값을 받아 다음과 같이 구성:

```python
def _build_system_prompt(subject: str, response_language: str, has_textbook: bool = False) -> str:
    base = (
        f"You are a study assistant helping a student learn {subject}. "
        "The user submits handwritten notes as images, sometimes with textbook reference text.\n\n"
        "Recognize ALL text in the image (it may mix multiple languages — e.g. the subject's "
        "language and the student's native-language annotations) and analyze the content holistically.\n\n"
        "If the subject is a language and the student wrote original text + translation, evaluate BOTH "
        "(translation accuracy, grammar, spelling). For non-language subjects, focus on conceptual "
        "correctness, reasoning, and terminology. Adapt your feedback to what the subject requires.\n\n"
        f"Respond naturally in {response_language} as a helpful tutor. "
        "Be specific about what is correct and what needs fixing. "
        "Use markdown formatting (bold, strikethrough) freely.\n\n"
    )
    # has_textbook 인용 규칙 블록은 분야 무관 → 그대로 유지
```

- `subject` 인자가 새로 필요 → `get_feedback`이 이미 받는 `language`를 그대로 넘기면 됨(`feedback_service.py:138` 호출부 수정).
- "If the subject is a language ... For non-language subjects ..." 한 문단이 분기 로직을 대체한다. LLM이 분야명을 보고 스스로 판단.

### 4.2 채팅 분야 주입 (P4)
현재 `ChatRequest`(`feedback.py:244` 부근)에는 분야 필드가 없다. 두 가지 선택:

- **(a) 권장)** `ChatRequest`에 `subject: str | None = None` optional 필드 추가, iOS 채팅 호출 시 `note.language` 전달. 프롬프트: `f"You are a tutor helping a student study {subject or 'their material'}."`
  - request 스키마에 **optional 필드 추가**라 기존 클라이언트 무영향(하위호환). 엄밀히는 계약 변경이나 optional+default라 BE 선반영 가능.
- (b) 분야 주입 없이 프롬프트만 "study tutor"로 중립화. iOS 변경 0. 단 분야 컨텍스트가 LLM에 안 감.

→ **(a) 채택.** iOS 채팅 호출부에서 `subject` 추가 전송. (Track 의존성: BE optional이므로 iOS 미반영이어도 안전, 병렬 가능.)

### 4.3 가이드 프롬프트 (P5/P6)
- 페이지 가이드: "English textbook"/"non-English speaker" 제거 → 교재 원문 언어를 가정하지 말고 "explain this textbook page faithfully in {response_language}; translate terms when the source differs from {response_language}".
- 챕터 가이드: JSON **키 이름은 절대 변경 금지**(`topic/key_concepts/study_order/common_mistakes/summary` — iOS·DB 파싱 호환). 키 설명문만 분야 중립화.

### 4.4 iOS 기본값/배지
- 기본값 `"en"`: 분야 미입력 시 fallback. "en"이 분야로 들어가면 LLM은 "English(영어 학습)"로 해석 → 기존 동작과 동일하므로 안전. 단 신규 사용자 혼란 방지 위해 placeholder를 분야 예시로 바꾸는 U1으로 충분.
- 배지 `.uppercased()`: 영문 분야는 대문자 유지가 자연스러우나 한글 분야("물리학")엔 무의미. 제거해도 영문 표시에 큰 손해 없음 → **제거 권장**.

---

## 5. 구현 단계 (Tracks)

```
        ┌─── Track A: Backend 프롬프트 범용화 (P1~P7)
시작 ───┤        (계약 변경 없음 → B와 완전 독립)
        └─── Track B: iOS UI 라벨 범용화 (U1~U4) + 채팅 subject 전송
```

**트랙 간 의존성:** 없음(병렬). API 스키마 무변경이라 계약 동결 불필요. §4.2(a)의 채팅 `subject`만 약한 연결 — BE가 optional로 받으므로 iOS 반영 순서 무관.

**인원별 배분:**
| 인원 | 추천 배분 |
|---|---|
| 1명 | A 먼저(핵심 가치) → B. 또는 파일 단위로 섞어서 |
| 2명 | 1인 Track A(BE 프롬프트 5곳), 1인 Track B(iOS) |

### Track A: Backend 프롬프트 범용화
**의존:** 없음
**내부 순서:** A-1~A-5 서로 다른 파일/함수 → 병렬 가능. 가장 복잡한 부분은 A-1(적응형 프롬프트 설계, §4.1)와 A-5(검색 품질 트레이드오프).
**작업량:** 중간 (프롬프트 카피 + 호출부 인자 1개 추가)

| ID | 파일 | 내용 |
|---|---|---|
| A-1 | `backend/app/services/feedback_service.py:15-38, 138` | `_build_system_prompt`에 `subject` 인자 추가, §4.1 적응형 프롬프트로 교체, 호출부에서 `language` 전달 |
| A-2 | `backend/app/services/feedback_service.py:85, 125` | 유저/인식 프롬프트 라벨 "Language:"→"Subject:" |
| A-3 | `backend/app/routers/feedback.py:316-318`, `ChatRequest`(~244) | chat system 프롬프트 중립화, `ChatRequest.subject` optional 추가, §4.2(a) |
| A-4 | `backend/app/services/guide_service.py:13-19, 45-55` | 페이지/챕터 가이드 프롬프트 중립화. JSON 키명 보존 |
| A-5 | `backend/app/services/retrieval_service.py:39-45` | 쿼리 리라이트 "language learning textbook"/"Translate to English" 제거 (§7 검증 필요) |

### Track B: iOS UI 범용화
**의존:** 없음 (A-3 채팅 subject는 BE optional이라 독립)
**내부 순서:** U1~U4 병렬. 작업량 작음.

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `ios-app/ScatchLM/Views/CreateNoteSheet.swift:24-25` | Section 라벨 "Subject", placeholder 다분야 예시 |
| B-2 | `ios-app/ScatchLM/Views/EditNoteSheet.swift:24-27` | 동일 통일 |
| B-3 | `ios-app/ScatchLM/Views/HomeView.swift:170` | 배지 `.uppercased()` 제거 검토 |
| B-4 | `ios-app/ScatchLM/Views/NoteView.swift:758` 채팅 호출부 | (§4.2(a) 채택 시) 채팅 요청에 `subject: note.language` 추가 전송 |

빌드 검증: CLAUDE.md 빌드 정책대로 실기기+시뮬레이터 빌드.

---

## 6. 확인 완료 사항 (코드 검증)

- `language` 분기 로직 부재: `rg "language" backend/app` 결과 조건문/매칭 없음. 프롬프트 주입(`feedback_service.py:85,125`)과 로깅뿐. → 재활용 안전.
- iOS `language` 사용처: 저장(`Note.swift:9,47`, `DatabaseService.swift:33`), 입력(`CreateNoteSheet.swift:7,25`, `EditNoteSheet.swift:27`), 최근목록(`CreateNoteSheet.swift:124`), 배지표시(`HomeView.swift:170`), 전송(`NoteView.swift:758`). 분기 없음.
- 시스템 프롬프트는 `language`를 **받지 않음**: `_build_system_prompt(response_language, has_textbook)` (`feedback_service.py:15`). 언어학습 전제는 하드코딩 문자열. → A-1에서 `subject` 인자 신규 추가 필요.
- 챕터 가이드 JSON 키: `topic/key_concepts/study_order/common_mistakes/summary` (`guide_service.py:48-52`). iOS/DB 파싱 호환 위해 키명 보존 필수.
- 채팅은 `language`/분야 값을 안 받음: `ChatRequest`에 분야 필드 없음 (`feedback.py:244` 부근, `current_page/note_id/textbook_id`만). → A-3에서 optional 추가.

### 6.x 미확인 항목
| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | iOS 채팅 호출부가 정확히 어느 파일/메서드에서 `/feedback/chat`을 부르는지, request 모델 구조 | `rg "feedback/chat" ios-app` 및 해당 호출 struct 확인 (Track B 착수 시) |
| 2 | `voyage-3-lite` 임베딩의 다국어 매칭 품질 — 강제 영어번역 제거가 한↔한/일↔일 검색에 미치는 실제 영향 | A-5 구현 후 기존 언어 교재로 RAG 회귀 테스트(`grep "RAG" uvicorn.log`) |
| 3 | 가이드 응답을 iOS가 어떤 키로 렌더링하는지(챕터 가이드 JSON) | iOS 가이드 뷰 파싱 코드 확인 후 키 보존 재확인 |

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| **쿼리 리라이트 영어번역 제거(A-5)가 기존 언어학습 RAG 검색 품질을 떨어뜨림** | 중 — 영어 교재를 외국어로 질문 시 매칭 저하 가능 | voyage-3-lite는 다국어 임베딩. 강제번역 대신 "원문 언어 유지"가 동일언어 교재엔 유리. 배포 전 기존 언어 노트로 검색 회귀 확인(6.x #2). 위험하면 "translate to the textbook's primary language if different"로 절충 |
| 적응형 프롬프트가 분야 판단을 LLM에 위임 → 애매한 분야명("English")에서 의도와 다른 피드백 | 저 | 프롬프트에 "subject is a language → 번역/문법" 명시. "en" 기본값은 기존과 동일 동작 |
| 챕터 가이드 JSON 키 설명 변경 중 실수로 키명 변경 → iOS 파싱 깨짐 | 중 | A-4에서 **키명 불변** 명시. 6.x #3로 iOS 파싱 키 재확인 |
| `ChatRequest.subject` 추가가 기존 클라이언트와 충돌 | 저 | optional + default None → 하위호환. iOS 미반영이어도 동작 |
| 사용자에게 "분야" 개념이 갑자기 노출되어 기존 언어학습 UX 혼란 | 저 | placeholder/라벨만 확장(언어 예시 + 타분야 예시 병기). 기능 흐름 불변 |
