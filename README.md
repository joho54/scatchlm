# ScatchLM

펜 드로잉 기반 학습 보조 iPad 앱. Apple Pencil 손글씨를 Claude Vision API로 인식하고 AI 피드백을 제공한다.

손으로 쓰며 정리하고 즉시 AI 피드백을 받는 학습 루프가 핵심이다. 교재 PDF를 노트에 연결하면 해당 페이지·챕터 텍스트를 컨텍스트로 주입해 그 교재 기준 피드백·채팅을 제공한다. 외국어(고전어 포함), 전공 공부, 기술 심화 등 범용 학습에 쓰인다.

## 주요 기능

- **드로잉 캔버스** — PencilKit 기반 손글씨 입력, 펜/지우개/실행취소
- **필기 인식 + AI 피드백** — 캔버스를 이미지로 캡처 → Claude Vision → 피드백 카드
- **교재 컨텍스트 주입** — 노트에 교재 PDF 연결 시 현재 페이지가 속한 챕터 텍스트를 LLM 프롬프트에 주입
- **피드백 후속 채팅** — 피드백 이후 같은 교재 컨텍스트로 이어지는 대화
- **페이지/챕터 학습 가이드** — PDF 페이지·챕터 단위 가이드 (lazy 캐싱)

## 아키텍처

```
scatchlm/
├── backend/     # FastAPI + PostgreSQL(pgvector) + Claude Vision API
├── ios-app/     # Swift/SwiftUI 네이티브 앱 (현재 활성)
├── mobile/      # React Native (Expo) — 레거시, 참조용
├── android-app/ # Android — 참조용
├── docs/        # 문서
└── SPEC.md      # 전체 명세서
```

### Backend (Python)
- **프레임워크**: FastAPI + uvicorn
- **DB**: PostgreSQL + pgvector + SQLAlchemy(async) + asyncpg (Docker Compose, 포트 5433)
- **인증**: Supabase Auth (JWT 검증, JIT 유저 프로비저닝)
- **LLM**: anthropic Python SDK (Claude Vision API)
- **임베딩**: Voyage AI (voyage-3-lite, 512차원) — RAG는 현재 비활성
- **PDF**: PyMuPDF (fitz)

### iOS App (Swift)
- **UI**: SwiftUI (@Observable, @State)
- **드로잉**: PencilKit (PKCanvasView)
- **PDF**: PDFKit (PDFView)
- **로컬 DB**: GRDB.swift (SQLite)
- **인증**: supabase-swift
- **프로젝트 생성**: XcodeGen (`project.yml` → `.xcodeproj`)

## 시작하기

### Backend

```bash
cd backend
make db-up      # PostgreSQL Docker 시작 (포트 5433)
make migrate    # alembic upgrade head
make serve      # uvicorn --reload (포트 8000)
make test       # pytest
```

환경변수는 `.env` 파일로 관리한다 (커밋 금지). Anthropic / Voyage / Supabase 키 필요.

### iOS App

```bash
cd ios-app
xcodegen generate                       # project.yml → .xcodeproj 생성

# 실기기(iPad) 빌드
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM \
  -destination 'id=<DEVICE_ID>' -allowProvisioningUpdates build

# 시뮬레이터 빌드 (컴파일 검증)
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM \
  -destination 'id=<SIMULATOR_ID>' build
```

API 호스트는 `ios-app/ScatchLM/Utilities/Config.swift`에서 관리한다 (개발 시 로컬 IP, 운영 시 `https://scatchlm.duckdns.org`).

## 주요 API 엔드포인트

| 엔드포인트 | 설명 |
|-----------|------|
| `POST /api/feedback` | 캔버스 이미지 → Claude Vision → 피드백 |
| `POST /api/feedback/chat` | 피드백 후속 채팅 (챕터 텍스트 컨텍스트 주입) |
| `POST /api/pdf/upload` | 교재 PDF 업로드 (TOC 추출, LLM 챕터 감지) |
| `GET /api/pdf/{id}/file` | PDF 파일 서빙 |
| `GET /api/pdf/{id}/chapters` | 챕터 목록 |
| `GET /api/pdf/{id}/guide` | 페이지 학습 가이드 |
| `GET /api/pdf/{id}/chapter-guide` | 챕터 학습 가이드 |
| `GET /api/pdf/textbooks` | 교재 목록 |

## 배포

`main`에 `backend/**` 변경을 푸시하면 GitHub Actions가 자동 배포한다 (`.github/workflows/deploy.yml`).

- **호스트**: Naver Cloud Platform VM (Ubuntu 24.04)
- **도메인**: `scatchlm.duckdns.org` (HTTPS는 Caddy + Let's Encrypt)
- **스토리지**: Naver Cloud Object Storage (S3 호환)
- **이미지**: GitHub Container Registry

DB 마이그레이션(`alembic upgrade head`)은 컨테이너 기동 시 Dockerfile CMD가 자동 적용한다. 수동 관리가 필요한 것은 `.env.prod`(시크릿)뿐이다 — scp 동기화에서 제외되어 VM에서 직접 관리한다. 상세 절차는 `backend/DEPLOY.md` 참고.

## 문서

- 전체 명세: [`SPEC.md`](SPEC.md)
- 배포: [`backend/DEPLOY.md`](backend/DEPLOY.md)
- 개발 가이드(빌드/로그/마이그레이션 컨벤션): [`CLAUDE.md`](CLAUDE.md)
