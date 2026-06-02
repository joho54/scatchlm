# ScatchLM

펜 드로잉 기반 학습 보조 iPad 앱. Apple Pencil 손글씨를 Claude Vision API로 인식하고, AI 피드백을 제공한다. 외국어(고전어 포함)·전공 공부·기술 심화 등 범용 학습에 쓰인다 — 손으로 쓰며 정리하고 즉시 AI 피드백을 받는 학습 루프가 핵심이며, 교재 PDF를 연결하면 RAG로 그 교재 기준 피드백·채팅을 제공한다.

## 프로젝트 구조

```
scatchlm/
├── backend/              # FastAPI 백엔드
│   ├── app/
│   │   ├── core/         # config, auth, database
│   │   ├── models/       # SQLAlchemy 모델 (user, textbook, document, guide, chapter, usage)
│   │   ├── routers/      # API 엔드포인트 (feedback, pdf, admin, devlog)
│   │   └── services/     # 비즈니스 로직 (feedback, guide, retrieval, embedding, indexing, pdf, chapter)
│   ├── tests/
│   ├── scripts/          # 마이그레이션 스크립트 (backfill_toc.py)
│   ├── docker-compose.yml
│   ├── Makefile
│   └── uploads/          # PDF 업로드 저장소
├── ios-app/              # Swift/SwiftUI 네이티브 앱 (현재 활성)
│   ├── ScatchLM/
│   │   ├── App/          # ScatchLMApp.swift
│   │   ├── Views/        # SwiftUI 뷰 (Login, Home, Note, PdfViewer, FeedbackChat, Settings 등)
│   │   ├── Models/       # GRDB 모델 (Note, NotePage, FeedbackRecord(+stroke_range_start/end), ChatMessageRecord 등)
│   │   ├── Services/     # DatabaseService, AuthService, APIClient, LogService
│   │   └── Utilities/    # Config
│   ├── project.yml       # XcodeGen 프로젝트 설정
│   └── ScatchLM.xcodeproj
├── mobile/               # React Native (Expo) — 레거시, 참조용
└── SPEC.md               # 전체 명세서
```

## 기술 스택

### Backend (Python)
- **프레임워크**: FastAPI + uvicorn
- **DB**: PostgreSQL + pgvector + SQLAlchemy (async) + asyncpg
- **인증**: Supabase Auth (JWT 검증, JIT 유저 프로비저닝)
- **LLM**: anthropic Python SDK (Claude Vision API, async)
- **임베딩**: Voyage AI (voyage-3-lite, 512차원)
- **PDF**: PyMuPDF (fitz)
- **컨테이너**: Docker Compose (pgvector/pgvector:pg16, 포트 5433)

### iOS App (Swift)
- **UI**: SwiftUI
- **드로잉**: PencilKit (PKCanvasView, UIViewRepresentable)
- **PDF**: PDFKit (PDFView, UIViewRepresentable)
- **로컬DB**: GRDB.swift (SQLite)
- **인증**: supabase-swift
- **HTTP**: URLSession (async/await)
- **마크다운**: MarkdownUI (채팅 시트)
- **상태관리**: @Observable, @State
- **프로젝트**: XcodeGen (project.yml → .xcodeproj)

## 개발 커맨드

### Backend
```bash
cd backend
make db-up                              # PostgreSQL Docker 시작 (포트 5433)
make serve                              # uvicorn --reload --host 0.0.0.0 (포트 8000)
make migrate                            # alembic upgrade head
make test                               # pytest
```

### iOS App
```bash
cd ios-app
xcodegen generate                       # project.yml → .xcodeproj 생성
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM \
  -destination 'id=00008103-000C65D43AEB001E' \
  -allowProvisioningUpdates build       # iPad 빌드
xcrun devicectl device install app \
  --device 00008103-000C65D43AEB001E \
  ~/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Debug-iphoneos/ScatchLM.app  # 설치

# 시뮬레이터 빌드 (컴파일 검증용 — 실기기 미연결 시 항상 함께 실행)
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM \
  -destination 'id=E9FA98C5-3953-4CAF-9076-81000B685E2F' build   # iPad (A16) Simulator
```

**빌드 정책**: 코드 변경 후에는 실기기 빌드와 시뮬레이터 빌드를 둘 다 수행해 컴파일을 검증할 것. 실기기가 미연결이면 시뮬레이터 빌드만으로도 컴파일 검증은 충분하다.

### 로그 확인

**Backend 로그**: `backend/logs/uvicorn.log` — `make serve`가 `tee`로 파이프
```bash
tail -f backend/logs/uvicorn.log
grep "FE" backend/logs/uvicorn.log       # iOS 앱 로그 (LogService → POST /api/dev/log/batch)
grep "LLM response" backend/logs/uvicorn.log  # LLM 호출 결과
grep "RAG\|Query rewrite" backend/logs/uvicorn.log  # RAG 검색 로그
```

**iOS 앱 로그**: `LogService`가 2초마다 `POST /api/dev/log/batch`로 백엔드에 전송
- 백엔드 로그에서 `[fe]` 또는 `FE` 태그로 필터링
- `appLog("tag", "message", ["key": "value"])` / `appLogError(...)` 사용

### DB 마이그레이션 (Alembic)

모델(`app/models/`) 변경 시 반드시 마이그레이션을 생성하고 적용할 것.

```bash
cd backend && source venv/bin/activate
alembic revision --autogenerate -m "설명"
alembic upgrade head
```

### iOS DB 마이그레이션 (GRDB)

`DatabaseService.swift`에서 `DatabaseMigrator`에 새 마이그레이션 등록:
```swift
migrator.registerMigration("v3_new_feature") { db in
    // 기존 마이그레이션 안에 추가하면 안 됨 — 이미 실행된 것은 스킵됨
}
```

## 주요 API 엔드포인트

- `POST /api/feedback` — 캔버스 이미지 → Claude Vision → 피드백 (response_language 지원)
- `POST /api/feedback/chat` — 피드백 후속 채팅 (RAG 지원, textbook_id로 교재 검색)
- `POST /api/pdf/upload` — 교재 PDF 업로드 (TOC 추출, LLM 챕터 감지, 임베딩 인덱싱)
- `GET /api/pdf/{id}/file` — PDF 파일 서빙
- `GET /api/pdf/{id}/chapters` — 챕터 목록
- `GET /api/pdf/{id}/guide` — 페이지 학습 가이드 (lazy 캐싱)
- `GET /api/pdf/{id}/chapter-guide` — 챕터 학습 가이드
- `GET /api/pdf/textbooks` — 교재 목록
- `POST /api/dev/log/batch` — 클라이언트 로그 수신

## RAG 파이프라인

1. **쿼리 리라이트**: Haiku로 사용자 질문을 검색 최적화 쿼리로 변환
2. **임베딩 검색**: Voyage AI 임베딩 → pgvector 코사인 유사도 (top_k=5)
3. **컨텍스트 주입**: 검색된 청크를 시스템 프롬프트에 포함
4. **출처 표기**: `[p.33]` 인라인 출처, `📖 교재 외 참고:` 구분

## 코드 컨벤션

- Backend: Python 3.11+, async/await 패턴, Pydantic 모델
- iOS: Swift 5.9+, SwiftUI, GRDB CodingKeys로 snake_case DB 컬럼 매핑
- 환경변수는 `.env` 파일로 관리 (커밋 금지)
- iOS 설정값은 `Config.swift` + `UserDefaults`

## 응답 원칙

- 회의주의적 시니어 엔지니어 태도로 대답할 것. 추측으로 행동하지 말고 확인 먼저.
- 디버깅 시 로그 기반으로 분석. BE 로그: `backend/logs/uvicorn.log`, FE 로그: 같은 파일에서 `FE` 필터.
- 구현에 어려움을 겪을 때 사용자에게 사과하는 대신, 명세나 문제에 대한 합의에 먼저 도달한 후 표준적인 솔루션을 제공할 것.

## 배포 (프로덕션)

상세 절차: `backend/DEPLOY.md`

### 인프라
- **호스트**: Naver Cloud Platform VM (`server-scatchlm-1`, Ubuntu 24.04, KR-1)
- **공인 IP**: `101.79.20.91`
- **도메인**: `scatchlm.duckdns.org` (DuckDNS, 토큰은 `.env.prod`)
- **VPC**: `scatchlm` / Subnet `scatchlm-subnet-public`
- **ACG**: 22(본인 IP), 80, 443 인바운드 허용
- **Object Storage**: Naver Cloud Object Storage (S3 호환, `boto3` 사용, endpoint `kr.object.ncloudstorage.com`)
- **Container Registry**: GitHub Container Registry (public 패키지 `ghcr.io/joho54/scatchlm-app:latest`)
- **HTTPS**: Caddy 컨테이너가 Let's Encrypt 자동 발급

### SSH
```bash
ssh scatchlm                            # alias (HostName: scatchlm.duckdns.org, User: root)
# 또는 ssh root@101.79.20.91
```
SSH 키: `~/.ssh/id_ed25519`. NCP pem(`/Users/johyeonho/scatchlm-secret/ssh-scatchlm.pem`)은 최초 root 비밀번호 복호화용으로만 사용.

### 배포 흐름
1. **로컬**: `docker build --platform linux/amd64 -t ghcr.io/joho54/scatchlm-app:latest backend/ && docker push ...`
2. **VM**: `cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod pull && up -d`

VM에는 빌드하지 않음 (디스크 10GB 절약). 설정 파일(`docker-compose.prod.yml`, `Caddyfile`, `init.sql`, `.env.prod`)은 `/opt/scatchlm/`에 위치.

### 스토리지 추상화 (`app/services/storage.py`)
- `STORAGE_BACKEND=local` (기본): `PDF_UPLOAD_DIR` 하위 파일 시스템
- `STORAGE_BACKEND=s3`: Naver Cloud Object Storage. boto3로 endpoint만 바꿔 호출
- PDF 서빙은 로컬이면 `FileResponse`, S3면 `StreamingResponse`로 자동 분기

## 참고

- 상세 명세: `SPEC.md`
- 배포: `backend/DEPLOY.md`
- iOS 개발환경 셋업: `mobile/README.md` (레거시 RN), `ios-app/project.yml`
- 인증: Supabase Auth (backend에서 JWT 검증, iOS에서 supabase-swift)
- API 호스트: `ios-app/ScatchLM/Utilities/Config.swift`에서 관리 (개발 시 로컬 IP, 운영 시 `https://scatchlm.duckdns.org`)
