# ScatchLM - 명세서

## 1. 개요

### 1.1 프로젝트 정의
ScatchLM은 펜 드로잉 기반 입력을 활용한 외국어 학습 보조 모바일 앱이다. 사용자가 드로잉 노트 위에 손글씨로 학습 내용을 작성하면, LLM이 이를 인식하고 드로잉 위에 직접 피드백을 제공한다.

### 1.2 문제 정의
- 외국어 학습 시 키보드 입력은 비효율적이다 (특수문자, 발음기호, 문법 표기 등)
- 기존 노트 앱은 학습 피드백 기능이 없다
- 기존 LLM 학습 도구는 텍스트 기반 입출력에 한정되어 있다

### 1.3 목표
- 펜 드로잉으로 자연스러운 입력 경험 제공
- 입력된 내용에 대해 LLM 기반 학습 피드백을 드로잉 노트 위에 직접 렌더링
- NotebookLM의 학습 보조 기능을 드로잉 노트 인터페이스로 확장

---

## 2. 사용자

### 2.1 타겟 사용자
- 외국어를 학습 중인 사용자
- 손글씨 노트 필기 습관이 있는 학습자
- 어휘, 문법, 작문 연습을 자주 하는 학습자

### 2.2 사용 시나리오

**시나리오 1: 어휘 연습문제 풀이**
1. 사용자가 노트에 교재 PDF를 연결하고, 참조 페이지 범위를 지정한다 (예: p.52-55)
2. 캔버스에 "24과 어휘 연습문제" 라고 쓰고, 아래에 문제 풀이 결과를 손글씨로 작성한다
3. 피드백 요청 버튼을 누른다
4. LLM이 해당 페이지의 교재 내용을 참조하여 손글씨를 인식하고, 풀이 결과 아래에 채점 및 피드백을 렌더링한다

**시나리오 2: 작문 교정**
1. 사용자가 외국어로 짧은 문장을 손글씨로 작성한다
2. 피드백 요청 버튼을 누른다
3. LLM이 문법/어휘 오류를 표시하고, 교정안을 해당 문장 아래에 렌더링한다

**시나리오 3: 단어 뜻 질문**
1. 사용자가 모르는 단어를 손글씨로 쓰고 "?" 를 붙인다
2. LLM이 해당 단어의 뜻, 예문, 발음을 단어 옆/아래에 렌더링한다

---

## 3. 기능 명세

### 3.1 핵심 기능

#### F1. 드로잉 캔버스
- 펜 입력을 받는 자유 드로잉 캔버스
- 펜 굵기, 색상 조절
- 지우개, 실행 취소/다시 실행
- 캔버스 무한 스크롤 (세로)

#### F2. 필기 인식 및 LLM 피드백
- 캔버스의 드로잉을 이미지로 캡처
- Claude Vision API에 이미지 + 컨텍스트 프롬프트 전송
- LLM 응답을 파싱하여 캔버스 위에 렌더링
- **교재 컨텍스트 연동**: 노트에 연결된 교재 PDF의 관련 섹션을 LLM 프롬프트에 포함

#### F2-1. 교재 PDF 연동
- 노트 생성/편집 시 PDF 파일 첨부 (선택, 서버 업로드)
- 서버에서 PDF 텍스트 추출 (PyMuPDF)
- 사용자가 참조 페이지 범위를 직접 지정 (예: "p.52-55")
- 지정된 페이지의 추출 텍스트를 LLM 프롬프트의 컨텍스트로 전송

#### F3. 피드백 렌더링
- 사용자 필기 영역의 바운딩 박스 감지
- 피드백을 필기 영역 아래에 텍스트/마크업으로 렌더링
- 피드백 영역은 시각적으로 구분 (색상, 배경 등)
- 피드백 영역은 편집 불가 (읽기 전용 레이어)

#### F4. 노트 관리
- 노트 생성/삭제/목록
- 노트별 제목, 생성일, 수정일
- 로컬 저장

### 3.2 교재 연동 강화 (MVP 이후)

#### F5. PDF 뷰어
- 캔버스 옆에서 교재 PDF를 직접 열람
- 스플릿 뷰 (좌: 캔버스, 우: PDF) 또는 슬라이드 오버 패널
- 페이지 탐색 (이전/다음, 페이지 번호 직접 입력)
- 현재 보고 있는 페이지 번호를 자동 추적

#### F5-1. 뷰 모드

노트 화면은 3가지 뷰 모드를 지원한다. 📖 버튼으로 모드를 순환한다.

| 모드 | 레이아웃 | 필기 대상 | 피드백 UI |
|------|----------|-----------|-----------|
| Canvas only | 캔버스 풀스크린 | 캔버스 | 인라인 카드 (필기 아래) |
| Split view | 좌 60% 캔버스 + 우 40% PDF | 캔버스 | 인라인 카드 (필기 아래) |
| PDF viewer only | PDF 풀스크린 + 필기 오버레이 | PDF 위 오버레이 | Bottom sheet (스택형) |

**PDF viewer only 모드 상세**:
- PDF를 풀스크린으로 표시하고, 그 위에 투명 드로잉 오버레이를 배치
- 사용자는 PDF 위에 직접 필기 (주석, 풀이 등)
- 피드백 요청 시 PDF 페이지 + 필기 오버레이를 합성 캡처하여 API 전송
- 피드백은 하단 Bottom sheet에 표시 (인라인 카드 방식 사용 불가 — PDF 콘텐츠가 배경을 차지하므로)

**Bottom sheet 피드백 UI**:
```
┌──────────────────────────────┐
│  PDF viewer (fullscreen)      │
│  + 필기 오버레이               │
│                               │
├───────────── ≡ ──────────────┤  ← 드래그 핸들
│  p.52 — "助詞の使い方"        │
│  ✓ 1번 정답, ✗ 2번: は→が    │
│  ───────────────────────────  │
│  p.53 — "動詞の活用"          │
│  3/5 정답. て형 복습 필요      │
│  ───────────────────────────  │
│  p.53 — "作文練習"            │  ← 최신 피드백
│  文法は正確. 語彙の多様性を... │
└──────────────────────────────┘
```

- 피드백을 시간순으로 스택 (채팅형). 각 항목에 **페이지 번호 + 인식 텍스트 + 피드백** 표시
- Snap point 3단계: **닫힘** (핸들만 보임) / **1/3** (최신 피드백 1~2개) / **2/3** (히스토리 스크롤)
- 시트를 닫으면 PDF 풀스크린으로 복귀
- 새 피드백 수신 시 자동으로 1/3 snap으로 열림

**컨텍스트 주입**: PDF viewer only 모드에서는 현재 보고 있는 페이지가 항상 존재하므로, `current_page` 컨텍스트가 자동 포함된다 (F6 로직 동일).

#### F6. 페이지 컨텍스트 자동 주입
- 사용자가 PDF 뷰어에서 페이지를 보고 있으면, 해당 페이지 텍스트를 LLM 컨텍스트에 자동 포함
- PDF 뷰어를 열지 않은 경우 RAG로 교재에서 관련 내용을 자동 검색 (fallback)
- 교재 형식(어휘 문제, 문법 문제, 작문 등)에 무관하게 LLM이 이미지 + 교재 텍스트로 판단

```
컨텍스트 합산 (배타적 선택이 아님):
  - RAG 검색 결과: 교재 연결 시 항상 실행 (recognized_text 기반 top-k 청크)
  - 현재 페이지 텍스트: PDF 뷰어가 열려 있으면 추가 포함
  - 교재 미연결 시: 컨텍스트 없이 일반 피드백
```

**설계 원칙**:
- 교재 컨텍스트는 가용한 만큼 최대한 제공한다. RAG와 현재 페이지는 배타적이지 않다.
- "채점"과 "일반 피드백"을 코드로 구분하지 않는다. 교재 컨텍스트가 있으면 LLM이 알아서 대조 채점하고, 없으면 일반 교정을 한다.
- 교재마다 연습문제 형식이 다르다. 의도 판별이나 타입 라우팅을 코드로 만들지 않는다. Vision API가 이미지에서 문제 구조를 읽고, 교재 텍스트와 대조하여 평가한다. 비정형성은 LLM이 흡수한다.

### 3.3 다크모드 + PDF 뷰어 테마

#### F7. 다크모드

앱 전체에 다크모드를 지원한다. 시스템 설정을 따르되, 앱 내 수동 전환도 가능.

**앱 UI 다크모드**:
- 배경: `#000000` (OLED true black) 또는 `#1c1c1e` (elevated)
- 카드/패널: `#2c2c2e` (elevated surface)
- 텍스트: `#ffffff` (primary), `#8e8e93` (secondary)
- 캔버스 배경: `#1c1c1e`, 노트 줄: `rgba(255,255,255,0.06)`
- 피드백 카드: frosted dark glass (`rgba(40,40,45,0.65)` + blur)
- 플로팅 버튼: dark glass 유지 (liquid glass 효과 동일, tint만 변경)

**전환 방식**:
- 시스템 설정 추종 (기본값)
- 설정 화면에서 수동 선택: 라이트 / 다크 / 시스템

#### F7-1. PDF 뷰어 테마

다크모드에서 PDF 원본(흰 배경)이 눈을 자극하는 문제를 해결한다. PDF 뷰어에 독립적인 테마를 적용.

**3단계 PDF 테마** (다크모드 활성 시 표시):

| 테마 | 네이티브 구현 | 용도 |
|------|-------------|------|
| Original | 없음 | 원본 그대로. 색상 정확도 필요 시 |
| Dim | `PDFView.layer.opacity = 0.75` 또는 반투명 dark overlay | 밝기만 줄임. 이미지/컬러 보존. 기본값(dark mode) |
| Dark | `CIColorInvert` + `CIHueAdjust(angle: π)` on CALayer | 완전 다크 배경. 텍스트 중심 PDF에 최적 |

**동작 규칙**:
- 라이트모드: PDF 테마 선택 UI 숨김 (항상 Original)
- 다크모드 진입 시: 자동으로 Dim 적용 (기본값)
- 사용자가 Dark 또는 Original로 변경 가능 (선택 기억)
- PDF 뷰어 헤더 또는 하단에 3-segment 컨트롤 배치

**구현 참고**:
- Apple PDFKit (`PDFView`) 사용 — 네이티브 렌더링
- `CIColorInvert` + `CIHueAdjust(angle: π)`는 색상을 원래대로 복원하되 밝기만 반전하는 트릭 (CSS `invert(1) hue-rotate(180deg)`의 네이티브 등가)
- `CALayer.compositingFilter` 또는 `PDFView`의 서브레이어에 `CIFilter` 적용
- 이미지가 포함된 PDF에서 Dark 모드 사용 시 이미지가 반전되는 한계 존재 → 사용자 선택에 위임
- React Native 브릿지: Expo Module 또는 네이티브 모듈로 PDFKit 래핑, 테마 prop 노출

```
[라이트모드]
PDF: Original (고정)

[다크모드]
PDF: ○ Original  ● Dim  ○ Dark
     └── 3-segment picker ──┘
```

### 3.4 부가 기능 (이후 버전)
- 학습 이력 추적
- 오답 노트 자동 생성
- 음성 입력 보조
- 클라우드 동기화
- 다국어 지원 설정 (학습 중인 언어 선택)
- 다양한 소스 타입 지원 (이미지, 텍스트 등 PDF 외 소스)

---

## 4. 시스템 아키텍처

### 4.1 전체 구조

```
┌──────────────────────────────────────┐
│        모바일 앱 (React Native)        │
│                                      │
│  ┌──────────────────────────────┐   │
│  │  드로잉 캔버스 (Skia)         │   │
│  │  - 스트로크 입력/렌더링        │   │
│  │  - 피드백 카드 인라인 렌더링   │   │
│  │  - 무한 스크롤 (가상 좌표계)   │   │
│  └─────────────┬────────────────┘   │
│                │                     │
│  ┌─────────────▼─────────────────┐   │
│  │       캔버스 매니저            │   │
│  │  - 스트로크 저장               │   │
│  │  - 이미지 캡처                 │   │
│  │  - 피드백 위치 관리            │   │
│  └─────────────┬─────────────────┘   │
│                │                     │
│  ┌─────────────▼─────────────────┐   │
│  │       로컬 저장소 (SQLite)     │   │
│  └───────────────────────────────┘   │
└────────────────┬─────────────────────┘
                 │ HTTPS
┌────────────────▼─────────────────────┐
│        백엔드 서버 (FastAPI)           │
│                                      │
│  ┌───────────────────────────────┐   │
│  │  API 엔드포인트               │   │
│  │  - POST /api/feedback         │   │
│  │  - POST /api/pdf/upload       │   │
│  │  - GET  /api/pdf/extract      │   │
│  │  - GET  /api/admin/usage      │   │
│  │  - POST /api/dev/log          │   │
│  │  - GET  /health               │   │
│  └─────────────┬─────────────────┘   │
│                │                     │
│  ┌─────────────▼─────────────────┐   │
│  │  PDF 텍스트 추출 (PyMuPDF)     │   │
│  └─────────────┬─────────────────┘   │
│                │                     │
│  ┌─────────────▼─────────────────┐   │
│  │  Claude Vision API (async)     │   │
│  │  2-pass: Haiku(인식) → Sonnet  │   │
│  │  응답 → JSON 파싱 → 반환       │   │
│  └───────────────────────────────┘   │
│                                      │
│  ┌───────────────────────────────┐   │
│  │  PostgreSQL                    │   │
│  │  - 교재 메타데이터              │   │
│  │  - pgvector (RAG 청크 임베딩)  │   │
│  │  - LLM 사용량 추적             │   │
│  └───────────────────────────────┘   │
└──────────────────────────────────────┘
                 │
┌────────────────▼─────────────────────┐
│        Supabase Auth (외부)           │
│  - 회원가입/로그인                     │
│  - JWT 발급 (ES256, JWKS)            │
│  - 세션 관리                          │
└──────────────────────────────────────┘
```

### 4.2 기술 스택

**모바일 (React Native)**

| 구성요소 | 기술 | 선정 이유 |
|----------|------|-----------|
| 프레임워크 | React Native (Expo) | 크로스플랫폼, 개발자 숙련도 |
| 드로잉 엔진 | react-native-skia | 고성능 2D 캔버스, Skia 기반 |
| 로컬 DB | SQLite (expo-sqlite) | 노트/스트로크 데이터 로컬 저장 |
| 상태 관리 | Zustand | 경량, 보일러플레이트 최소 |
| HTTP 클라이언트 | axios | 백엔드 API 통신 |

**백엔드 (FastAPI)**

| 구성요소 | 기술 | 선정 이유 |
|----------|------|-----------|
| 프레임워크 | FastAPI | 네이티브 async, AI 서비스 표준 |
| ASGI 서버 | uvicorn | 경량 고성능 ASGI 서버 |
| 통신 방식 | HTTP (JSON) | 요청 → 대기 (스피너) → 구조화된 JSON 반환 |
| PDF 파싱 | PyMuPDF (fitz) | 페이지별 텍스트 추출, 경량 |
| LLM 연동 | anthropic (Python SDK, async) | Claude Vision API 비동기 호출 |
| 인증 | Supabase Auth (JWKS/ES256) | 외부 인증 서비스, PyJWT로 토큰 검증 |
| DB | PostgreSQL + SQLAlchemy (async) | 비동기 ORM, 사용자/교재 메타데이터 관리 |

### 4.3 API 호출 흐름

```
[모바일 앱]                        [FastAPI 백엔드]               [Claude API]
     │                                  │                            │
     │  1. POST /api/feedback           │                            │
     │  {image(PNG), noteId,            │                            │
     │   currentPage, textbookId}       │                            │
     │ ─────────────────────────────▶   │                            │
     │                                  │  2. 컨텍스트 합산           │
     │  [스피너 표시]                    │  (현재 페이지 + RAG 검색)   │
     │                                  │                            │
     │                                  │  3. 프롬프트 구성 + API 호출 │
     │                                  │ ──────────────────────────▶ │
     │                                  │                            │
     │                                  │  4. 응답 수신 + JSON 파싱   │
     │                                  │ ◀────────────────────────── │
     │                                  │                            │
     │  5. JSON 응답 반환               │                            │
     │ ◀─────────────────────────────   │                            │
     │                                  │                            │
     │  6. JSON → 캔버스 위 피드백 렌더링│                            │
```

---

## 5. 화면 구성

### 5.1 화면 목록

| 화면 | 설명 | 상태 |
|------|------|------|
| 로그인 | Supabase 이메일/비밀번호 인증 | ✅ 완료 |
| 홈 (노트 목록) | 저장된 노트 리스트, 새 노트 생성/삭제 | ✅ 완료 |
| 드로잉 노트 | 메인 캔버스 + 도구 모음 + 피드백 버튼 | ✅ 코드 완료 |
| 설정 | 학습 언어 선택, 서버 연결 설정 | 미착수 |

### 5.2 드로잉 노트 화면 레이아웃

```
┌─────────────────────────────┐
│  ← 뒤로    노트 제목    ⋮   │  ← 상단 바
├─────────────────────────────┤
│                             │
│   (사용자 손글씨 영역)       │
│   24과 어휘 연습문제         │
│   풀이: ...                 │
│                             │
│   ┌───────────────────────┐ │
│   │ ✓ 1번 정답            │ │  ← LLM 피드백 (인라인 카드)
│   │ ✗ 3번: A → B 수정     │ │
│   │ 총평: ...             │ │
│   └───────────────────────┘ │
│                             │
│                             │
├─────────────────────────────┤
│  ✏️ 🔴 ◯  ⌫  ↩  │ 💬 피드백 │  ← 하단 도구 모음
└─────────────────────────────┘
```

---

## 6. 데이터 모델

> **로컬 (SQLite)**: Note, Stroke, Feedback — 모바일 앱에서 관리
> **서버 (PostgreSQL)**: User, TextbookSource — FastAPI 백엔드에서 관리

### 6.1 사용자 (User) — 서버
> 인증은 Supabase Auth에서 관리. 서버 DB에는 Supabase user ID를 참조키로 저장.

| 필드 | 타입 | 설명 |
|------|------|------|
| id | String (UUID) | Supabase Auth user ID |
| email | String | 이메일 |
| createdAt | DateTime | 최초 접속일 |

### 6.2 노트 (Note) — 로컬
| 필드 | 타입 | 설명 |
|------|------|------|
| id | String (UUID) | 고유 식별자 |
| title | String | 노트 제목 |
| createdAt | DateTime | 생성일 |
| updatedAt | DateTime | 수정일 |
| language | String | 학습 언어 코드 (예: "ja", "en") |

### 6.3 스트로크 (Stroke) — 로컬
| 필드 | 타입 | 설명 |
|------|------|------|
| id | String (UUID) | 고유 식별자 |
| note_id | String | 소속 노트 ID |
| svg_path | String | Skia Path의 SVG 문자열 표현 |
| color | String (hex) | 펜 색상 (예: "#000000") |
| width | number | 펜 굵기 |
| created_at | DateTime | 작성 시각 |

### 6.4 교재 소스 (TextbookSource) — 서버
| 필드 | 타입 | 설명 |
|------|------|------|
| id | String (UUID) | 고유 식별자 |
| userId | String (UUID) | 소유 사용자 ID |
| noteId | String | 연결된 노트 ID |
| fileName | String | 원본 PDF 파일명 |
| serverPath | String | 서버 저장 경로 |
| totalPages | number | 총 페이지 수 |
| fileSize | number | 파일 크기 (bytes) |
| createdAt | DateTime | 등록일 |

### 6.5 피드백 (Feedback) — 로컬
| 필드 | 타입 | 설명 |
|------|------|------|
| id | String (UUID) | 고유 식별자 |
| noteId | String | 소속 노트 ID |
| content | TEXT | AI 응답 JSON 문자열 (스키마 비의존 — 아래 참조) |
| position | {x: number, y: number} | 렌더링 위치 (캔버스 좌표) |
| boundingBox | {x, y, width, height} | 피드백 영역 크기 |
| createdAt | DateTime | 생성일 |

#### 6.5.1 응답 포맷 설계

`content` 컬럼은 TEXT 타입으로, AI 응답 JSON 문자열을 그대로 저장한다. 응답의 내부 구조는 DB 스키마가 관여하지 않는다.

**단일 응답 타입**: 교재 형식(어휘, 문법, 작문 등)에 따른 타입 분기를 두지 않는다. LLM이 `feedback` 필드에 자유 형식으로 피드백을 작성하며, FE는 Paragraph 렌더링으로 통일한다.

```typescript
// FE (TypeScript)
interface AIResponse {
  type: "feedback";           // 확장 여지만 남겨둠. 당분간 "feedback" 단일값.
  recognized_text: string;    // Vision API가 인식한 원문
  feedback: string;           // 자유 형식 피드백 (LLM이 문제 유형에 맞게 구조화)
  summary: string;            // 한국어 요약
}
```

```python
# BE (Pydantic)
class AIResponse(BaseModel):
    type: Literal["feedback"]
    recognized_text: str
    feedback: str
    summary: str
```

**설계 원칙**: 교재 연습문제의 형식 다양성(어휘 채점, 빈칸 채우기, 작문 교정 등)은 LLM이 흡수한다. 의도 판별이나 타입별 프롬프트 라우팅을 코드로 만들지 않는다. 시스템 프롬프트 하나로 모든 형식을 처리한다.

---

## 7. 토큰 최적화 전략

토큰 비용은 서비스 지속가능성의 핵심 변수다. 아래 전략을 계층적으로 적용한다.

### 7.1 입력 최적화 (이미지 토큰 절감)

#### 7.1.1 선택 영역 캡처
- 캔버스 전체가 아닌 **새로 작성된 영역만 크롭**하여 전송
- 스트로크의 바운딩 박스를 추적하고, 마지막 피드백 이후 추가된 스트로크 영역만 캡처
- 예: 전체 캔버스 2000x3000px → 신규 필기 영역 800x400px (토큰 ~80% 절감)

```
┌─────────────────────────┐
│  (이전 필기 - 전송 안 함) │
│  ...                    │
├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤
│  ┌───────────────────┐  │
│  │ 신규 필기 (캡처)   │  │  ← 이 영역만 API에 전송
│  └───────────────────┘  │
└─────────────────────────┘
```

#### 7.1.2 이미지 해상도 조절
- 손글씨 인식에 필요한 최소 해상도를 실험으로 결정
- 기본값: 긴 변 기준 1024px 리사이즈 (Claude Vision 권장)
- 단순 텍스트 필기: 768px까지 낮출 수 있음

#### 7.1.3 흑백 변환
- 컬러 캔버스를 grayscale로 변환 후 전송
- 색상 정보가 의미 없는 경우 이미지 용량 절감 → 토큰 절감

### 7.2 컨텍스트 최적화 (텍스트 토큰 절감)

#### 7.2.1 컨텍스트 전달 전략
- 첫 요청: 이미지 + (PDF 뷰어가 열려 있으면) 현재 페이지 텍스트
- 후속 요청: 이미지 + 현재 페이지 텍스트 + 직전 피드백 요약 (1턴)
- 이전 이미지는 재전송하지 않음

```
[요청 1] 이미지(필기) + 교재 52p 텍스트
[요청 2] 이미지(필기) + 교재 53p 텍스트 + "이전: 24과 어휘 중 1,3번 오답"
```

#### 7.2.2 시스템 프롬프트 최소화
- 시스템 프롬프트를 짧고 구조화된 형태로 유지
- 학습 언어, 피드백 형식 등 고정 파라미터만 포함
- 단일 프롬프트로 모든 교재 형식을 처리 (의도 판별/타입 라우팅 없음)

#### 7.2.3 구조화된 출력 요청
- LLM 응답을 JSON 형식으로 제한하여 불필요한 텍스트 출력 방지
- 출력 토큰 절감 + 파싱 안정성 확보

```json
{
  "type": "feedback",
  "recognized_text": "原文をそのまま書く",
  "feedback": "1번 정답. 2번: 助詞「は」→「が」 (주격 조사 혼동). 3번 정답.",
  "summary": "2/3 정답. 조사 사용을 복습하세요."
}
```

### 7.3 호출 빈도 최적화

#### 7.3.1 배치 처리
- 실시간 피드백이 아닌 **사용자가 명시적으로 요청**할 때만 API 호출
- 자동 호출 트리거 없음 (MVP)

#### 7.3.2 캐싱
- 동일한 필기에 대한 중복 요청 방지
- 스트로크 데이터의 해시값으로 캐시 키 생성
- 변경 없이 재요청 시 로컬 캐시에서 피드백 반환

#### 7.3.3 모델 티어링
- 단순 작업 (단어 뜻 질문): Haiku (저비용, 빠른 응답)
- 복잡한 작업 (작문 교정, 문법 분석): Sonnet
- 작업 유형은 사용자 선택 또는 기본값(Sonnet)으로 결정

```
사용자 요청
    │
    ▼
  모델 선택 (사용자 설정 기반)
    ├─ 단순 (단어, 뜻) ──→ Haiku  ($0.25/1M input)
    └─ 복잡 (교정, 분석) ──→ Sonnet ($3/1M input)
```

### 7.4 비용 추정 (MVP 기준)

| 시나리오 | 이미지 크기 | 입력 토큰 (이미지+교재) | 출력 토큰 | 모델 | 예상 비용/건 |
|----------|------------|----------------------|-----------|------|-------------|
| 단어 질문 (교재 없이) | 800x400 | ~400 | ~100 | Haiku | ~$0.0002 |
| 어휘 풀이 채점 (교재 3p) | 1024x600 | ~800 + ~1500 | ~300 | Sonnet | ~$0.008 |
| 작문 교정 (교재 2p) | 1024x800 | ~1200 + ~1000 | ~500 | Sonnet | ~$0.009 |

하루 평균 20회 사용 기준: **월 $3~6 수준** (선택 영역 캡처 + 모델 티어링 + 교재 컨텍스트 포함)

### 7.5 사용자 비용 가시성
- 서버에서 사용자별 API 사용량 추적 (요청 횟수, 토큰 수)
- 설정 화면에서 누적 사용량 표시
- 월간 예산 상한 설정 기능 (상한 도달 시 요청 차단)

---

## 8. 제약 조건 및 고려사항

### 8.1 기술적 제약
- **API 레이턴시**: Claude Vision API 호출에 2~5초 소요 예상. 스피너로 대기 UX 제공.
- **오프라인**: MVP에서는 온라인 필수. 오프라인 시 피드백 요청 비활성화.
- **PDF 용량 제한**: 업로드 최대 50MB. 초과 시 업로드 거부.

### 8.2 비용
- 토큰 최적화 전략(7장)을 적용하여 비용 최소화
- MVP 단계에서는 서버에서 API 키 관리 (환경변수), Supabase Auth로 접근 제어

### 8.3 개인정보
- 손글씨 이미지가 외부 API로 전송됨을 사용자에게 명시
- 로컬 저장 우선, 클라우드 동기화는 선택적

---

## 9. MVP 범위

### 포함
- [x] 드로잉 캔버스 (펜 입력, 지우개, 색상)
- [x] 캔버스 이미지 캡처
- [x] Claude Vision API 연동 (피드백 요청/수신)
- [x] 피드백 캔버스 위 렌더링
- [x] 노트 저장/불러오기
- [x] 학습 언어 설정
- [x] 교재 PDF 연동 (업로드, 텍스트 추출, 페이지 범위 수동 지정)

### 제외 (이후 버전)
- [x] 교재 챕터 자동 분할 + 선택 UI (TOC 추출 + LLM fallback) → M10
- [x] RAG 기반 교재 컨텍스트 자동 검색 (임베딩 기반, PDF 뷰어 미사용 시 fallback) → M7
- [x] PDF 뷰어 + 페이지 컨텍스트 자동 주입 → M8
- [x] 페이지/챕터 학습 가이드 (LLM 생성, lazy 캐싱) → M10
- [ ] 음성 입력
- [ ] 클라우드 동기화
- [ ] 학습 이력/통계
- [ ] 오답 노트 자동 생성

---

## 10. 개발 마일스톤

| 단계 | 내용 | 산출물 | 상태 |
|------|------|--------|------|
| M1 | 프로젝트 세팅 (RN + FastAPI) + 드로잉 캔버스 구현 | 펜 입력이 가능한 캔버스 화면, FastAPI 기본 구조 | ✅ 완료 (iPad 디바이스 검증 완료) |
| M2 | 백엔드 피드백 API + Claude Vision 연동 | POST /api/feedback → JSON 응답 | ✅ 완료 |
| M3 | 무한 스크롤 캔버스 + 피드백 인라인 렌더링 | 캔버스 세로 무한 스크롤, 피드백을 캔버스 위에 직접 렌더링 | ✅ 완료 |
| M4 | PDF 업로드 + 교재 컨텍스트 연동 | POST /api/pdf/upload, 페이지 범위 지정, 컨텍스트 전송 | ✅ 완료 |
| M5 | 노트 관리 | 노트 CRUD, 로컬 저장 (SQLite) | ✅ 완료 |
| M7 | RAG 기반 교재 컨텍스트 자동 검색 | 임베딩 파이프라인, 벡터 검색, 자동 컨텍스트 주입 | ✅ 완료 |
| M8 | PDF 뷰어 + 페이지 컨텍스트 | F5 PDF 뷰어, F6 페이지 컨텍스트 자동 주입, 컨텍스트 우선순위 로직 | ✅ 완료 |
| M9 | Apple PencilKit 마이그레이션 | 네이티브 필기 엔진, PKDrawing 저장, 피드백 오버레이 | ✅ 완료 |
| M10 | PDF 스마트 기능 | 네이티브 PDF 뷰어, TOC 추출/LLM 감지, 페이지/챕터 학습 가이드 | ✅ 완료 |
| M6 | 폴리싱 | UX 개선, 에러 처리, 설정 화면 | 🔶 진행 중 |

### 10.2 M3 상세 스펙: 무한 스크롤 캔버스 + 피드백 인라인 렌더링

#### 목표
- 현재 화면 고정 캔버스 → 세로 무한 스크롤로 확장
- 별도 패널(FeedbackOverlay) → 캔버스 위에 손글씨 아래 인라인 렌더링

#### 설계

**스크롤**: Skia `<Group transform={[{ translateY: -scrollOffset }]}>` 로 가상 스크롤. 캔버스 크기는 화면 유지, 컨텐츠만 이동. 뷰포트 밖 스트로크는 렌더링 스킵 (컬링).

**제스처 분리**: Apple Pencil(Stylus) → 드로잉, 손가락(Touch) → 스크롤. `Gesture.Simultaneous(drawPan, scrollPan)` + `manualActivation` + `pointerType` 판별. 시뮬레이터에서는 `__DEV__` 폴백으로 모든 터치를 드로잉 처리.

**피드백 렌더링**: Skia `RoundedRect` (배경 카드) + `Paragraph` (텍스트). 피드백 위치 = 스트로크 바운딩 박스의 maxY + 24px 아래. 시스템 폰트 사용 (`matchFont`).

**좌표계**: 스트로크를 캔버스 가상 좌표로 저장 (`canvasY = screenY + scrollOffset`). 기존 스트로크는 scrollOffset=0 기준이므로 자동 호환.

#### 구현 순서

| 단계 | 파일 | 내용 |
|------|------|------|
| 1 | `src/types/index.ts` | `FeedbackRenderItem` 타입 추가 |
| 2 | `src/hooks/useDrawing.ts` | scrollOffset, 좌표 변환, onScroll 콜백 |
| 3 | `src/components/DrawingCanvas.tsx` | 제스처 분리, Group transform, 뷰포트 컬링, 피드백 Skia 렌더링 |
| 4 | `app/note/[id].tsx` | FeedbackOverlay 제거, feedbackItems 상태, 위치 계산, 자동 스크롤 |
| 5 | `src/components/FeedbackOverlay.tsx` | 삭제 |

#### 주의 사항
- 시뮬레이터에서 Apple Pencil 미지원 → `__DEV__` 폴백 필수
- `makeImageFromView`는 현재 뷰포트만 캡처 → MVP 허용, 향후 Skia Surface로 개선
- 피드백 위치를 SQLite에 실제 좌표로 저장 (현재 0으로 하드코딩된 부분 교체)

### 10.3 M7 상세 스펙: RAG 기반 교재 컨텍스트 자동 검색

#### 목표
현재: 사용자가 PDF 페이지 범위를 수동 지정 (예: "p.52-55")
목표: 손글씨 인식 결과를 기반으로 교재에서 관련 내용을 자동 검색하여 LLM 컨텍스트에 주입

#### 현재 시스템과의 관계
- M4에서 구현된 수동 페이지 범위 지정은 유지 (사용자 오버라이드용)
- RAG는 교재 연결 시 항상 실행. PDF 뷰어의 현재 페이지 텍스트와 합산하여 컨텍스트 제공 (M8)
- `textbook_context` 파라미터는 동일하게 사용, 소스만 변경

#### 아키텍처

```
[PDF 업로드 시 — 인덱싱 파이프라인]
PDF → PyMuPDF 텍스트 추출 → 청킹 (300-500 토큰) → 임베딩 → pgvector 저장

[피드백 요청 시 — 검색 파이프라인]
손글씨 이미지
  → Claude Vision (텍스트 인식)
  → recognized_text를 임베딩
  → pgvector 유사도 검색 (top-k=3)
  → 검색된 청크를 textbook_context로 주입
  → Claude (피드백 생성)
```

#### 기술 선택

| 구성요소 | 선택 | 근거 |
|----------|------|------|
| 벡터 DB | pgvector (PostgreSQL 확장) | 별도 인프라 불필요, 기존 DB에 추가 |
| 임베딩 모델 | Voyage AI `voyage-3-lite` | Anthropic 파트너, 비용 저렴 ($0.02/1M 토큰) |
| 청킹 | 단락 기반 (300-500 토큰) | 교재 구조를 존중하는 자연 단위 |
| 유사도 | 코사인 유사도 | 임베딩 모델 권장 |

#### 데이터 모델

**DocumentChunk — 서버 (PostgreSQL + pgvector)**

| 필드 | 타입 | 설명 |
|------|------|------|
| id | UUID | PK |
| textbook_id | UUID | FK → TextbookSource |
| user_id | UUID | 소유자 |
| chunk_index | int | 청크 순서 |
| page_start | int | 시작 페이지 |
| page_end | int | 끝 페이지 |
| content | text | 청크 텍스트 |
| embedding | vector(512) | 임베딩 벡터 (Voyage AI voyage-3-lite) |
| created_at | timestamp | 생성일 |

#### API 변경

**기존 API 수정:**
- `POST /api/pdf/upload` — 업로드 후 비동기로 청킹+임베딩 실행. 응답에 `indexing_status` 추가.
- `POST /api/feedback` — `textbook_id`만 있고 `page_start/page_end` 없으면 RAG 자동 검색.

**신규 API:**
- `GET /api/pdf/{id}/indexing-status` — 인덱싱 진행 상태 조회
- `GET /api/pdf/{id}/chunks` — 청크 목록 조회 (디버깅용)

#### 피드백 흐름 변경

```
[현재: 수동]
사용자: 페이지 52-55 지정 → 해당 텍스트 추출 → LLM 컨텍스트

[RAG: 자동]
사용자: 교재만 연결, 페이지 미지정
  → 1단계: Claude Vision으로 손글씨 인식 (lightweight, Haiku)
  → 2단계: recognized_text를 임베딩
  → 3단계: pgvector에서 top-3 유사 청크 검색
  → 4단계: 검색된 청크 + 이미지로 최종 피드백 (Sonnet)
```

주의: 2단계 인식은 저비용 모델(Haiku)로 수행. 최종 피드백만 Sonnet 사용.

#### 구현 순서

| 단계 | 파일 | 내용 |
|------|------|------|
| 1 | DB migration | pgvector 확장 활성화, DocumentChunk 테이블 생성 |
| 2 | `models/document.py` | DocumentChunk SQLAlchemy 모델 (pgvector 컬럼) |
| 3 | `services/embedding_service.py` | Voyage AI 임베딩 호출, 청킹 로직 |
| 4 | `services/retrieval_service.py` | 쿼리 임베딩 → pgvector 코사인 유사도 검색 |
| 5 | `routers/pdf.py` 수정 | 업로드 시 백그라운드 인덱싱 트리거 |
| 6 | `routers/feedback.py` 수정 | 페이지 미지정 시 RAG 자동 검색 분기 |
| 7 | `services/feedback_service.py` 수정 | 2단계 파이프라인 (인식 → 검색 → 피드백) |
| 8 | 테스트 | 인덱싱, 검색, 피드백 통합 테스트 |

#### 비용 추정

| 항목 | 비용 | 빈도 |
|------|------|------|
| 임베딩 (인덱싱) | ~$0.001/페이지 | PDF 업로드 시 1회 |
| 임베딩 (쿼리) | ~$0.00001/건 | 피드백 요청마다 |
| pgvector | 무료 | PostgreSQL 확장 |
| Haiku 인식 (1단계) | ~$0.0002/건 | 자동 검색 시 |

기존 피드백 비용($0.008/건) 대비 RAG 추가 비용은 ~$0.001로 무시할 수준.

#### 주의 사항
- 인덱싱은 비동기 (BackgroundTasks). 대용량 PDF는 수 초 소요.
- 벡터 차원은 임베딩 모델에 종속 (Voyage AI voyage-3-lite = 512차원)
- pgvector 인덱스 (ivfflat 또는 hnsw)는 데이터량이 적은 초기에는 불필요, 추후 추가
- 수동 페이지 범위 지정이 항상 RAG보다 우선 (사용자 의도 존중)

### 10.4 M8 상세 스펙: PDF 뷰어 + 페이지 컨텍스트

#### 목표
- 교재 PDF를 캔버스 옆에서 직접 열람
- 사용자가 보고 있는 페이지의 텍스트를 LLM 컨텍스트에 자동 주입
- RAG(M7)와 합산하여 교재 컨텍스트 최대 제공

#### 선행 조건
- M4 (PDF 업로드 + 텍스트 추출) 완료 필수 — 서버에 PDF가 존재해야 함
- M7 (RAG)은 선택적 — 없어도 페이지 직접 참조로 동작, 있으면 fallback으로 활용

#### UI 설계

**뷰 모드**: 📖 버튼으로 3가지 모드를 순환한다 (Canvas only → Split → PDF only → Canvas only). PDF 미연결 시 📖 버튼은 교재 연결 flow 트리거.

**모드 1: Canvas only** (기존, PDF 패널 닫힘):
```
┌─────────────────────────────────────────┐
│                                         │
│   캔버스 (드로잉, 풀스크린)               │
│   (사용자 필기)                          │
│   ┌────────────────┐                    │
│   │ 피드백 카드     │                    │
│   └────────────────┘                    │
│                                         │
├─────────────────────────────────────────┤
│  ✏️  ⌫  ↩  │ 📖  │ 💬 피드백            │
└─────────────────────────────────────────┘
```

**모드 2: Split view** (좌 60% 캔버스, 우 40% PDF):
```
┌──────────────────────┬─────────────────┐
│                      │                 │
│   캔버스 (드로잉)     │   PDF 뷰어      │
│                      │   ← p.52 →     │
│   (사용자 필기)       │   (교재 내용)    │
│                      │                 │
│   ┌────────────────┐ │                 │
│   │ 피드백 카드     │ │                 │
│   └────────────────┘ │                 │
│                      │                 │
├──────────────────────┴─────────────────┤
│  ✏️  ⌫  ↩  │ 📖  │ 💬 피드백          │
└────────────────────────────────────────┘
```

**모드 3: PDF viewer only** (PDF 풀스크린 + 필기 오버레이 + bottom sheet 피드백):
```
┌─────────────────────────────────────────┐
│                                         │
│   PDF 뷰어 (풀스크린)                    │
│   ← p.52 →                             │
│   (교재 내용)                            │
│   ~ ~ ~ 필기 오버레이 ~ ~ ~             │
│                                         │
├──────────────── ≡ ──────────────────────┤  ← 드래그 핸들
│  p.52 — "助詞の使い方"                   │
│  ✓ 1번 정답, ✗ 2번: は→が               │
│  ─────────────────────────────────────  │
│  p.53 — "作文練習"                       │  ← 최신
│  文法は正確. 語彙の多様性を...            │
├─────────────────────────────────────────┤
│  ✏️  ⌫  ↩  │ 📖  │ 💬 피드백            │
└─────────────────────────────────────────┘
```

- PDF viewer only 모드에서 필기는 PDF 위 투명 드로잉 오버레이에 수행
- 피드백은 bottom sheet에 시간순 스택으로 표시 (채팅형)
- Bottom sheet snap point: 닫힘 (핸들만) / 1/3 (최신 1~2개) / 2/3 (히스토리 스크롤)
- 새 피드백 수신 시 자동으로 1/3 snap으로 열림
- 피드백 요청 시 PDF 페이지 + 필기 오버레이를 합성 캡처하여 API 전송

**공통**:
- 페이지 이동: 스와이프 또는 하단 < p.52 > 네비게이션
- PDF 미연결 시 📖 버튼은 교재 연결 flow 트리거 (기존 handleAttachTextbook)

#### 컨텍스트 합산 로직

RAG 검색 결과와 현재 페이지 텍스트는 배타적이지 않다. 둘 다 가용하면 합산한다.

```python
# feedback_service.py
async def resolve_textbook_context(
    textbook_id: str | None,
    current_page: int | None,       # PDF 뷰어에서 보고 있는 페이지
    recognized_text: str | None,    # RAG 검색 쿼리 (M7)
) -> str | None:
    parts = []

    # 보고 있는 페이지 (있으면 항상 포함)
    if current_page is not None and textbook_id:
        page_text = await extract_page_text(textbook_id, current_page)
        if page_text:
            parts.append(f"[현재 페이지 {current_page}]\n{page_text}")

    # RAG 검색 (교재 연결됐으면 항상 실행)
    if textbook_id and recognized_text:
        chunks = await rag_search(recognized_text, textbook_id)
        if chunks:
            parts.append(f"[관련 교재 내용]\n{chunks}")

    return "\n\n".join(parts) if parts else None
```

#### API 변경

`POST /api/feedback` 파라미터 추가:
```
기존: image, note_id, language, textbook_id, page_start, page_end, previous_context
추가: current_page (int, optional) — PDF 뷰어에서 보고 있는 페이지 번호
```

`current_page`가 있으면 `page_start/page_end` 대신 해당 페이지 텍스트를 컨텍스트로 사용. 기존 수동 페이지 범위 지정도 유지 (하위 호환).

#### 기술 선택

| 구성요소 | 선택지 | 비고 |
|----------|--------|------|
| PDF 렌더링 | `react-native-pdf` 또는 WebView + PDF.js | 네이티브 성능 vs 호환성 트레이드오프 |
| 페이지 추적 | `onPageChanged` 콜백 → `currentPage` 상태 | 실시간 추적 |
| 레이아웃 | 조건부 flex (PDF 열림: 60/40, 닫힘: 100/0) | 애니메이션은 후순위 |

#### 구현 순서

| 단계 | 파일 | 내용 |
|------|------|------|
| 1 | `src/components/PdfViewer.tsx` | PDF 렌더링 컴포넌트, 페이지 네비게이션, onPageChanged 콜백 |
| 2 | `app/note/[id].tsx` | 스플릿 뷰 레이아웃, PDF 패널 토글, currentPage 상태 |
| 3 | `src/services/feedback.ts` | `current_page` 파라미터 추가 |
| 4 | `routers/feedback.py` | `current_page` 파라미터 수신, 컨텍스트 우선순위 로직 |
| 5 | `services/feedback_service.py` | `resolve_textbook_context` 함수 구현 |
| 6 | 테스트 | 페이지 컨텍스트 주입, 우선순위 분기, PDF 뷰어 통합 테스트 |

#### 주의 사항
- PDF 렌더링 라이브러리의 네이티브 빌드 필요 (CocoaPods 재설치)
- 스플릿 뷰에서 캔버스 너비가 변하면 기존 스트로크 좌표에 영향 없음 (가상 좌표계이므로)
- `makeImageFromView` 캡처 범위가 캔버스 영역만 포함되는지 확인 필요 (PDF 패널 제외)
- 대용량 PDF(100p+)의 페이지 렌더링 성능 모니터링

### 10.5 M9 상세 스펙: Apple PencilKit 마이그레이션

#### 목표
현재 Skia 기반 드로잉 엔진을 Apple PencilKit으로 교체하여 Apple Notes 수준의 자연스러운 필기감을 확보한다.

#### 현재 문제 (Skia 한계)
- `path.lineTo()`만 사용하여 곡선 보간 없음 — 빠른 필기 시 각진 획
- Apple Pencil의 압력/기울기 데이터 미활용 — 균일한 획 두께
- JS 브리지 경유 (GestureHandler → Reanimated → runOnJS → state) — 렌더링 지연
- Predictive Touch 미지원 — 펜촉과 렌더링 사이 체감 지연
- 소프트웨어 레벨 palm rejection만 적용 (`pointerType` 체크)

#### PencilKit이 해결하는 것
| 항목 | Skia (현재) | PencilKit |
|------|------------|-----------|
| 잉크 렌더링 | Canvas 2D (Skia) | Metal 네이티브 (~9ms 지연) |
| Predictive Touch | 미지원 | 시스템 레벨 예측 렌더링 |
| 필압/기울기 | 미사용 | 자동 반영 (획 두께/투명도 동적 변화) |
| Palm Rejection | `pointerType` 분기 | 시스템 레벨 |
| 잉크 스무딩 | 없음 | 자동 (Bezier 보간) |
| 도구 종류 | 펜/지우개 | 펜, 연필, 마커, 만년필, 수채화, 크레용 등 |

#### 라이브러리 선택

| 라이브러리 | 장점 | 단점 | 권장 |
|-----------|------|------|------|
| `expo-pencilkit-ui` | Expo Modules API 네이티브 통합, 설정 최소 | API 표면 작음 (도구 선택 API 없음) | ✅ 1차 검토 |
| `react-native-pencil-kit` | 풍부한 API (도구, ruler, drawingPolicy), Fabric 지원 | config plugin 필요, Expo Go 불가 | 2차 대안 |

두 라이브러리 모두 Expo Go 불가 → `expo run:ios` (dev client) 필수. 현재 iPad 물리 디바이스 배포 환경이므로 문제 없음.

#### 아키텍처

```
┌─────────────────────────────────────┐
│  React Native View (Z-stack)        │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  Layer 2: Skia Canvas         │  │  ← 피드백 카드 렌더링 (pointerEvents="none")
│  │  (Paragraph, RoundedRect)     │  │
│  ├───────────────────────────────┤  │
│  │  Layer 1: PencilKitView       │  │  ← 필기 입력 (네이티브)
│  │  (PKCanvasView)               │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘

터치 라우팅:
  - Apple Pencil → PencilKitView (네이티브 처리)
  - 손가락 스크롤 → PencilKitView (UIScrollView 네이티브)
  - 피드백 오버레이 → pointerEvents="none" (터치 통과)
```

**핵심 원칙**: PencilKit은 필기 입력 전용, 피드백 렌더링은 기존 Skia 오버레이 유지. 두 레이어의 스크롤 오프셋을 동기화한다.

#### 데이터 모델 변경

**현재 (Skia)**:
```
Stroke { svg_path: string, color: string, width: number }
→ 개별 스트로크를 SVG 문자열로 저장
```

**변경 후 (PencilKit)**:
```
Drawing { data: string (base64), created_at: DateTime }
→ PKDrawing 전체를 base64 blob으로 저장 (노트당 1개)
```

- PKDrawing은 불투명 바이너리 포맷. 개별 스트로크 접근 불가 (PencilKit 없이 렌더링 불가)
- 기존 SVG 스트로크 데이터와 호환 불가 → 마이그레이션 시 기존 노트는 읽기 전용 또는 재작성
- 압력, 기울기, 속도 정보가 PKDrawing에 포함됨

SQLite 스키마:
```sql
-- 기존 strokes 테이블은 유지 (레거시 노트 호환)
-- 신규 테이블 추가
CREATE TABLE drawings (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES notes(id),
  data TEXT NOT NULL,          -- PKDrawing base64
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### 이미지 캡처 (Claude Vision API 연동)

| 기능 | 현재 (Skia) | PencilKit |
|------|------------|-----------|
| 전체 캡처 | `makeImageFromView(ref)` | `getBase64PngData({scale})` |
| 신규 영역 캡처 | `Skia.Surface` + `drawPath()` + 바운딩 박스 | PKDrawing `image(from:rect, scale:)` — 래퍼 확장 필요 |

`captureNewStrokesBase64()` (선택 영역 캡처)는 rect 기반 렌더링 API가 래퍼에 노출되지 않을 수 있음. 이 경우:
- 옵션 A: 라이브러리 fork하여 `getBase64PngData({rect, scale})` 추가
- 옵션 B: 전체 캡처 후 JS에서 크롭 (토큰 비용 증가 허용)
- 옵션 C: 전체 캡처로 단순화 (MVP 접근, 향후 최적화)

#### 무한 스크롤

PKCanvasView는 UIScrollView 서브클래스로 네이티브 스크롤을 지원한다. 그러나 현재 래퍼 라이브러리들이 `contentSize` 제어를 노출하지 않음.

대응 방안:
1. **래퍼 확장**: `contentSize` prop 추가 (네이티브 모듈 수정)
2. **페이지 기반**: 고정 높이 PKCanvasView를 FlatList로 관리 (페이지 단위)
3. **충분히 큰 고정 캔버스**: contentSize를 충분히 크게 설정 (예: 10000px)

옵션 1이 가장 자연스럽지만 라이브러리 fork 필요. POC에서 옵션 3으로 검증 후 판단.

#### 피드백 오버레이 스크롤 동기화

PencilKit의 스크롤과 Skia 오버레이의 스크롤을 동기화해야 한다.

```typescript
// PencilKitView의 onScroll 이벤트 → Skia 오버레이 scrollOffset 동기화
<PencilKitView
  onScroll={(e) => {
    const offsetY = e.nativeEvent.contentOffset.y;
    setFeedbackScrollOffset(offsetY);
  }}
/>
<Canvas style={{ position: 'absolute', pointerEvents: 'none' }}>
  <Group transform={[{ translateY: -feedbackScrollOffset }]}>
    {/* 피드백 카드 렌더링 */}
  </Group>
</Canvas>
```

주의: `onScroll` 이벤트가 래퍼에 노출되지 않을 경우, 네이티브 모듈 확장 필요.

#### Android 대응

PencilKit은 iOS 전용. Android 전략:

- **현재**: Skia 기반 드로잉 엔진을 Android 전용으로 유지
- **인터페이스 추상화**: 공통 DrawingEngine 인터페이스 정의, 플랫폼별 구현 교체

```typescript
// 공통 인터페이스
interface DrawingEngine {
  captureBase64(): Promise<string>;
  captureNewStrokesBase64(): Promise<string | null>;
  saveDrawing(): Promise<void>;
  loadDrawing(noteId: string): Promise<void>;
  undo(): void;
  redo(): void;
  clear(): void;
  setTool(tool: DrawingTool): void;
}

// 플랫폼 분기
const DrawingCanvas = Platform.OS === 'ios'
  ? PencilKitCanvas   // PencilKit 네이티브
  : SkiaCanvas;       // 기존 Skia 유지
```

iPad가 1차 타겟이므로 Android Skia 엔진은 현재 수준 유지. 향후 Stylus API 활용 개선 가능.

#### 구현 순서

| 단계 | 내용 | 파일 |
|------|------|------|
| 0 | **POC** — PencilKitView 임베딩, 필기, PNG 캡처, 스크롤 동작 검증 | 별도 브랜치 |
| 1 | DrawingEngine 인터페이스 정의 | `src/types/drawing.ts` |
| 2 | PencilKitCanvas 컴포넌트 구현 | `src/components/PencilKitCanvas.tsx` |
| 3 | PKDrawing 저장/로드 (SQLite drawings 테이블) | `src/services/database.ts` |
| 4 | 피드백 오버레이 분리 (Skia Canvas, pointerEvents="none") | `src/components/FeedbackOverlay.tsx` |
| 5 | 스크롤 동기화 (PencilKit ↔ 피드백 오버레이) | `src/hooks/useDrawing.ts` |
| 6 | 이미지 캡처 연동 (captureBase64 → feedback API) | `src/components/PencilKitCanvas.tsx` |
| 7 | 기존 SkiaCanvas를 Android 전용으로 분기 | `src/components/DrawingCanvas.tsx` |
| 8 | 기존 노트 마이그레이션 (SVG → 읽기 전용 or 재렌더링) | `src/services/database.ts` |

#### 선행 조건
- M3 (무한 스크롤 + 피드백 렌더링) 완료 ✅
- iPad 물리 디바이스 빌드 환경 ✅
- Expo dev client (`expo run:ios`) 환경 ✅

#### 리스크 및 검증 항목 (POC에서 확인)

| 리스크 | 검증 방법 | 블로커 여부 |
|--------|----------|------------|
| 래퍼가 contentSize 미노출 → 무한 스크롤 불가 | 큰 고정 캔버스(10000px)로 테스트 | 중 — fork로 해결 가능 |
| onScroll 미노출 → 피드백 오버레이 동기화 불가 | 래퍼 API 확인, 네이티브 이벤트 테스트 | 고 — fork 필수 가능성 |
| rect 기반 캡처 미노출 → 선택 영역 캡처 불가 | 전체 캡처 후 크롭으로 대체 가능 | 저 |
| 기존 SVG 스트로크 → PKDrawing 변환 불가 | 기존 노트 읽기 전용 처리로 우회 | 저 |

#### 주의 사항
- POC를 먼저 수행하여 래퍼 라이브러리의 실제 API 한계를 확인할 것. 명세의 "래퍼 확장 필요" 항목이 실제로 필요한지는 POC 결과에 따라 결정.
- PencilKit 도입은 iOS 전용 네이티브 의존성을 추가한다. Expo Go 사용 불가가 확정되므로 개발 워크플로우가 `expo run:ios` 기반으로 고정됨.
- PKDrawing 포맷은 Apple 독점. 향후 크로스플랫폼 렌더링이나 웹 뷰어가 필요하면 별도 래스터라이즈 파이프라인이 필요.

### 10.6 M10 상세 스펙: PDF 스마트 기능

#### 목표
- PDF 뷰어를 네이티브(react-native-pdf, iOS PDFKit)로 교체하여 깜빡임/핀치줌 문제 해결
- 교재 챕터 구조 자동 추출 (TOC + LLM fallback)
- 페이지/챕터별 학습 가이드 생성 (lazy 캐싱)

#### 구현 완료 항목

| 기능 | 설명 |
|------|------|
| 네이티브 PDF 뷰어 | `react-native-pdf` (iOS PDFKit). 페이징, 핀치줌, 스와이프 네이티브 처리 |
| 페이지 북마크 | `last_page` 컬럼 — 마지막 본 페이지 자동 저장/복원 |
| PDF 열림 상태 저장 | `pdf_open` 컬럼 — 뷰어 토글 상태 유지 |
| TOC 추출 | PDF 업로드 시 `PyMuPDF get_toc()` → chapters 테이블 저장 |
| LLM 챕터 감지 | TOC 없는 PDF에서 페이지 헤더 분석으로 챕터 구조 자동 판별 |
| 목차 UI | ☰ 버튼 → 바텀시트에 챕터 목록, 탭으로 페이지 이동 |
| 페이지 가이드 | 📚 버튼 → 현재 페이지의 학습 가이드 (핵심 암기, 연습 과제, 연결) |
| 챕터 가이드 | 목차에서 📚 → 챕터 전체 요약 (핵심 개념, 학습 순서, 자주 하는 실수) |
| 가이드 캐싱 | `page_guides` 테이블에 lazy 캐싱. 두 번째 조회부터 즉시 반환 |

#### API 엔드포인트

| Method | Path | 설명 |
|--------|------|------|
| GET | `/api/pdf/{id}/guide?page=N` | 페이지 학습 가이드 |
| GET | `/api/pdf/{id}/chapter-guide?chapter_id=X` | 챕터 학습 가이드 |
| GET | `/api/pdf/{id}/chapters` | 챕터 목록 조회 |

#### DB 테이블

- `chapters` — textbook_id, level, title, page_start, page_end
- `page_guides` — textbook_id, page, content (JSON), 캐시용

### 10.7 Liquid Glass 네이티브 구현

#### 목표
플로팅 UI 요소(FAB pill, back 버튼, 피드백 카드)에 Apple Liquid Glass 스타일의 경계면 빛 굴절 효과를 네이티브로 구현한다.

#### 배경
- 디자인 프로토타입(HTML)에서 SVG `feDisplacementMap` 기반으로 효과 검증 완료
- 웹 기술(SVG filter)은 RN/네이티브에서 사용 불가
- iOS 네이티브 CIFilter 체인으로 동일 효과를 GPU 가속으로 구현

#### 아키텍처

```
React Native (TypeScript)
  │
  └─ <LiquidGlassView style={...} radius={28} bezelWidth={18} thickness={80}>
       {children}  ← 버튼 콘텐츠
     </LiquidGlassView>
  │
  └─ Expo Module (Swift) — "expo-liquid-glass"
       │
       └─ LiquidGlassView: UIView
            ├─ backgroundCapture()     ← 뒤 콘텐츠 스냅샷
            ├─ generateDisplacementMap() ← Snell's law 기반 (Canvas → CIImage)
            ├─ applyRefraction()       ← CIFilter 체인
            └─ compositeSpecular()     ← 경계면 하이라이트 합성
```

#### CIFilter 파이프라인

```swift
// 1. 배경 캡처 → CIImage
let background = CIImage(image: captureBackground())

// 2. Displacement map 생성 (Snell's law, 1회 생성 후 캐시)
let displacementMap = generateDisplacementMap(
    width: bounds.width,
    height: bounds.height,
    radius: radius,
    bezelWidth: bezelWidth,
    glassThickness: glassThickness,
    refractiveIndex: 1.5
)

// 3. CIDisplacementDistortion — 경계면 굴절
let displaced = background.applyingFilter("CIDisplacementDistortion", parameters: [
    kCIInputDisplacementImageKey: displacementMap,
    kCIInputScaleKey: refractionScale
])

// 4. 채도 부스트 (유리 통과 시 색감 강조)
let saturated = displaced.applyingFilter("CIColorControls", parameters: [
    kCIInputSaturationKey: 1.4
])

// 5. Specular highlight 합성
let specular = generateSpecularHighlight(...)
let final = saturated.applyingFilter("CIAdditionCompositing", parameters: [
    kCIInputBackgroundImageKey: specular
])
```

#### Displacement Map 생성 (Snell's Law)

HTML 데모의 JS 로직을 Swift로 포팅:

```swift
func generateDisplacementMap(width: CGFloat, height: CGFloat, radius: CGFloat, 
                              bezelWidth: CGFloat, glassThickness: CGFloat,
                              refractiveIndex: CGFloat) -> CIImage {
    // 1D: 반경 방향 변위 계산 (Snell's law)
    let eta = 1.0 / refractiveIndex
    var precomputed: [CGFloat] = []
    for i in 0..<128 {
        let x = CGFloat(i) / 128.0
        let surfaceHeight = pow(1 - pow(1 - x, 4), 0.25) // convex_squircle
        let derivative = /* 수치 미분 */
        let normal = normalize([-derivative, -1])
        let refracted = snellRefract(incident: [0, -1], normal: normal, eta: eta)
        let displacement = refracted.x * (surfaceHeight * bezelWidth + glassThickness) / refracted.y
        precomputed.append(displacement)
    }
    
    // 2D: 각 픽셀에 대해 경계면까지 거리 → 1D 맵 참조 → R/G 채널 인코딩
    let bitmap = createBitmap(width: Int(width), height: Int(height))
    // ... (HTML 데모의 calculateDisplacementMap2D와 동일 로직)
    
    return CIImage(cgImage: bitmap.cgImage!)
}
```

#### Props (React Native 인터페이스)

```typescript
interface LiquidGlassProps {
  // 형상
  radius: number;           // border-radius (px)
  bezelWidth: number;       // 굴절이 일어나는 경계 두께 (px)
  glassThickness: number;   // 유리 두께 → displacement 강도

  // 광학
  refractiveIndex?: number; // 굴절률 (기본 1.5)
  refractionScale?: number; // displacement 강도 배수 (기본 1.0)
  specularOpacity?: number; // 경계 하이라이트 투명도 (0~1, 기본 0.5)
  
  // 기타
  blurRadius?: number;      // 배경 블러 (기본 0, frosted glass 효과 시 사용)
  saturation?: number;      // 채도 부스트 (기본 1.4)
  
  children: React.ReactNode;
  style?: ViewStyle;
}
```

#### 사용 예시

```tsx
// FAB Pill
<LiquidGlassView 
  radius={28} 
  bezelWidth={18} 
  glassThickness={80}
  style={{ position: 'absolute', bottom: 20, right: 20 }}
>
  <PillButtons />
</LiquidGlassView>

// Back button
<LiquidGlassView 
  radius={18} 
  bezelWidth={12} 
  glassThickness={50}
  style={{ position: 'absolute', top: 12, left: 12, width: 36, height: 36 }}
>
  <BackIcon />
</LiquidGlassView>

// Feedback card (blur + refraction)
<LiquidGlassView 
  radius={14} 
  bezelWidth={20} 
  glassThickness={100}
  blurRadius={30}
  style={{ margin: 20 }}
>
  <FeedbackContent />
</LiquidGlassView>
```

#### 배경 캡처 전략

| 방법 | 장점 | 단점 |
|------|------|------|
| `UIView.drawHierarchy(in:afterScreenUpdates:)` | 정확 | 메인스레드, 느림 |
| `UIView.snapshotView(afterScreenUpdates:)` | 빠름 | CIImage 변환 불가 |
| `CALayer.render(in:)` | GPU 친화적 | 일부 뷰 누락 가능 |
| **`UIWindowScene` 스크린샷 + crop** | 모든 레이어 포함 | 권한 이슈 없음 (자체 앱) |

**추천**: `drawHierarchy` + 스크롤 시 throttle (16ms). Displacement map은 shape 변경 시에만 재생성 (캐시).

#### 성능 최적화

- **Displacement map 캐시**: shape(radius, bezelWidth, size)가 같으면 재생성 안 함
- **배경 캡처 throttle**: 스크롤 이벤트에서 `CADisplayLink` 동기화 (60fps 이하로 제한)
- **CIContext 재사용**: 앱 라이프사이클 동안 하나의 `CIContext(options: [.useSoftwareRenderer: false])` 공유
- **Metal 가속**: `CIContext(mtlDevice:)` 사용으로 GPU 파이프라인 보장
- **크기 제한**: 캡처 이미지를 @1x 해상도로 다운샘플 (refraction에 고해상도 불필요)

#### 구현 순서

| 단계 | 내용 | 파일 |
|------|------|------|
| 0 | **POC** — CIDisplacementDistortion 단독 테스트, 성능 측정 | 별도 브랜치 |
| 1 | Expo Module 스캐폴딩 (`expo-liquid-glass`) | `modules/expo-liquid-glass/` |
| 2 | Displacement map 생성 (Swift, Snell's law 포팅) | `ios/DisplacementMapGenerator.swift` |
| 3 | Specular highlight 생성 | `ios/SpecularGenerator.swift` |
| 4 | LiquidGlassView 구현 (배경 캡처 + CIFilter 체인) | `ios/LiquidGlassView.swift` |
| 5 | React Native Props 바인딩 | `ios/LiquidGlassModule.swift` |
| 6 | TypeScript 래퍼 + 사용 예시 | `src/components/LiquidGlass.tsx` |
| 7 | 스크롤 동기화 (배경 업데이트 트리거) | `src/hooks/useLiquidGlass.ts` |
| 8 | 성능 프로파일링 + 최적화 | — |

#### 선행 조건
- Expo dev client 환경 ✅
- iPad 물리 디바이스 ✅
- M9 (PencilKit) 완료 권장 — 피드백 오버레이 레이어 구조가 확정된 후 glass 효과 적용이 자연스러움

#### 리스크

| 리스크 | 영향 | 대응 |
|--------|------|------|
| `CIDisplacementDistortion` 성능 부족 (60fps 미달) | 스크롤 시 끊김 | Metal shader 직접 구현으로 대체 |
| 배경 캡처 지연 (>16ms) | 글래스 내용이 1프레임 뒤처짐 | 캡처 해상도 낮춤 + predictive offset |
| PencilKit 레이어와 캡처 충돌 | 필기 내용이 glass에 안 보임 | `afterScreenUpdates: true` 또는 합성 순서 조정 |

#### Fallback (성능 미달 시)

CIFilter 파이프라인이 60fps를 못 맞추면:
1. **Static refraction**: 스크롤 중에는 단순 blur, 스크롤 멈춤 후 refraction 적용
2. **Gradient border only**: displacement 없이 spectral gradient border + blur (디자인 HTML의 첫 번째 데모 수준)
3. **최종 fallback**: `UIVisualEffectView` (.systemUltraThinMaterial) — Apple 기본 글래스

### 10.1 향후 검토 항목

- **AI 학습 플래너**: 축적된 피드백 데이터(반복 실수 패턴, 노트별 숙련도)를 기반으로 복습 계획을 자동 생성. Spaced repetition 연동 가능. 현재 스펙 범위 완료 및 데이터 축적 후 검토.

### 10.2 인프라 (마일스톤 외)

| 항목 | 상태 |
|------|------|
| Supabase Auth 연동 (BE JWKS/ES256 검증 + Mobile 클라이언트) | ✅ 완료 |
| 백엔드 테스트 (14건: auth 5, feedback 4, pdf 5) | ✅ 전체 통과 |
| Xcode 26.4 + iOS 빌드 환경 | ✅ 완료 (iPad 물리 디바이스 배포로 전환) |
| SQLite 로컬 DB (notes, strokes, feedbacks 테이블) | ✅ 완료 |
| 드로잉 캔버스 (react-native-skia + GestureHandler) | ✅ 완료 (iPad 검증 완료) |
| 노트 목록 UI (생성/삭제/탐색) | ✅ 완료 |
| 로그인 UI (Supabase Auth) | ✅ 완료 |
| 스트로크 자동 저장/로드 (SVG path ↔ SQLite) | ✅ 완료 |
| Docker Compose (pgvector) + Makefile | ✅ 완료 |
| 동적 API 호스트 (app.config.js getLocalIP) | ✅ 완료 |
| expo-dev-client (물리 디바이스 Metro 연결) | ✅ 완료 |
| JIT 유저 프로비저닝 (첫 API 요청 시 자동 생성) | ✅ 완료 |
