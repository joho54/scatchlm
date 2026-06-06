# ScatchLM

펜 드로잉 기반 학습 보조 iPad 앱. Apple Pencil 손글씨를 Claude Vision API로 인식하고, AI 피드백을 제공한다. 외국어(고전어 포함)·전공 공부·기술 심화 등 범용 학습에 쓰인다 — 손으로 쓰며 정리하고 즉시 AI 피드백을 받는 학습 루프가 핵심이며, 교재 PDF를 연결하면 해당 페이지·챕터 텍스트를 컨텍스트로 주입해 그 교재 기준 피드백·채팅을 제공한다.

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

**로그 레벨과 전송 경로 (디버깅 시 반드시 숙지)**:
- `appLog`=info, `appLogWarn`=warn, `appLogError`=error, **`appLogDebug`=debug**.
- **`appLogDebug`는 Debug 빌드(`make reinstall-dev`)에서만 백엔드로 전송**된다. Release 빌드는 클라이언트(`LogService.enqueue`)가 debug를 드롭 — `#if DEBUG` 밖에서 `if level == "debug" { return }`. 즉 실유저(Release/TestFlight) 트래픽엔 debug가 안 온다.
- 빌드 대상 백엔드는 `Config.apiBaseURL`이 결정: Debug 빌드는 `devApiHost` UserDefaults **미설정 시 운영**, 설정 시 `http://<host>:18000`(로컬). Release는 항상 운영.
- **debug 로그는 stdout(docker logs)에 `[debug]` 마커로 찍히고, 동시에 `app_logs` 테이블에도 적재**된다(`devlog.py:_emit`). 과거엔 `log.debug()`라 stdout에서 묻혔으나 INFO로 승격함. 그래도 누락이 의심되면 `app_logs`가 단일 진실 — `/check-prod-db`로 `SELECT … FROM app_logs WHERE tag='…'` 조회. (`[access]` API 호출 로그는 `_emit`을 안 거쳐 app_logs에 없음 — docker logs grep만 가능.)
- 고빈도 렌더/내부 상태(canvas geom 등)는 `appLogDebug`로, 사용자 행동/네트워크는 `appLog`로 — 운영 노이즈·비용 분리.

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
- `POST /api/feedback/chat` — 피드백 후속 채팅 (current_page → 해당 챕터 전체 텍스트 컨텍스트 주입)
- `POST /api/pdf/upload` — 교재 PDF 업로드 (TOC 추출, LLM 챕터 감지). 임베딩 인덱싱은 `ENABLE_EMBEDDING=false` 기본 비활성
- `GET /api/pdf/{id}/file` — PDF 파일 서빙
- `GET /api/pdf/{id}/chapters` — 챕터 목록
- `GET /api/pdf/{id}/guide` — 페이지 학습 가이드 (lazy 캐싱)
- `GET /api/pdf/{id}/chapter-guide` — 챕터 학습 가이드
- `GET /api/pdf/textbooks` — 교재 목록
- `POST /api/dev/log/batch` — 클라이언트 로그 수신

## 교재 컨텍스트 주입

`/api/feedback`는 `textbook_id`가 있으면 다음 우선순위로 교재 텍스트를 LLM 컨텍스트에 주입한다 (`feedback.py`):

1. **수동 페이지 범위**: `page_start`/`page_end`가 오면 해당 페이지 텍스트 (`extract_pdf_text`)
2. **현재 챕터 전체**: `current_page`가 오면 그 페이지를 포함하는 가장 좁은 챕터의 전체 텍스트. iOS는 교재 연결 시 항상 `current_page`를 함께 보내므로 정상 흐름은 이 경로를 탄다.

### Voyage 임베딩 RAG (현재 비활성)

pgvector 기반 의미 검색(`retrieval_service.search_relevant_chunks`: Haiku 쿼리 리라이트 → Voyage 임베딩 → 코사인 유사도)이 구현돼 있으나 **사실상 미사용**이다:

- 호출 지점은 `feedback.py`의 `if textbook_id and not context_parts:` 하나뿐 — 위 1·2가 빈 컨텍스트를 낼 때(텍스트 레이어 없는 스캔 PDF 등)만 도달하는 degenerate fallback.
- 매 업로드마다 발생하던 임베딩 비용·지연을 없애기 위해 `ENABLE_EMBEDDING` 플래그(기본 `false`, `config.py`)로 `index_textbook`의 청킹+임베딩을 차단했다. 되살리려면 `.env`에 `ENABLE_EMBEDDING=true`.
- `retrieval_service`의 `search_by_chapter/page/text`, `_detect_*`는 호출되지 않는 dead code(하이브리드 검색 미완성 잔재).

## 코드 컨벤션

- Backend: Python 3.11+, async/await 패턴, Pydantic 모델
- iOS: Swift 5.9+, SwiftUI, GRDB CodingKeys로 snake_case DB 컬럼 매핑
- 환경변수는 `.env` 파일로 관리 (커밋 금지)
- iOS 설정값은 `Config.swift` + `UserDefaults`

## 응답 원칙

- 회의주의적 시니어 엔지니어 태도로 대답할 것. 추측으로 행동하지 말고 확인 먼저.
- 디버깅 시 로그 기반으로 분석. BE 로그: `backend/logs/uvicorn.log`, FE 로그: 같은 파일에서 `FE` 필터.
- **로그가 부족하면 로그를 더 심어라.** 현재 계측만으로 원인을 확정할 수 없으면(예: 깜빡임 같은 렌더링 글리치인데 frame/bounds/contentOffset/zoom 같은 기하값이 안 찍힘), 추측으로 고치지 말고 먼저 의심 지점에 로그(`appLog`/`appLogDebug`/BE 로그)를 추가한 뒤 재현 → 로그로 원인을 좁혀라. 원인 확정 후 디버그 전용 로그는 정리(또는 `appLogDebug`로 강등)할 것.
- 구현에 어려움을 겪을 때 사용자에게 사과하는 대신, 명세나 문제에 대한 합의에 먼저 도달한 후 표준적인 솔루션을 제공할 것.
- **낙관 금지 — 검증 안 된 걸 "완료/해결/출시 가능"으로 선언하지 말 것.** 기능이 **실기기에서 실제로 동작함을 직접 확인**하기 전엔 "고쳐졌다/된다/출시 가능"이라고 말하지 않는다. 시뮬레이터 통과·빌드 성공·코드상 맞음은 "동작 확인"이 아니다(특히 PencilKit·제스처·PDFKit 등 기기 종속 기능).
- **원인 미규명을 "환경/OS/디바이스 탓"으로 합리화하지 말 것.** 후보를 배제했다고 원인을 찾은 게 아니다. 근거(로그/재현/계측)로 *지목*하지 못했으면 **"원인 미규명"이라고 명시**하고 그렇게 보고한다. "아마 OS 버그", "디바이스 런타임 wedge" 같은 추정은 시스템 로그 등 직접 증거가 있을 때만, 추정임을 분명히 해서 말한다.
- **결과를 있는 그대로 보고.** 실기기에서 안 되면 "안 된다"고 말한다 — 빌드/시뮬레이터 성공으로 덮지 않는다.

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

### 배포 흐름 — CI/CD 자동 (GitHub Actions)

**`main`에 `backend/**` 변경을 푸시하면 자동 배포된다.** 수동 빌드/SSH 불필요.

워크플로: `.github/workflows/deploy.yml` (트리거: `push` to `main` (`backend/**` 또는 워크플로 파일), 또는 수동 `workflow_dispatch`).
1. **build-and-push**: `backend/` 이미지(linux/amd64) 빌드 → `ghcr.io/joho54/scatchlm-app:latest` + `:<sha12>` push (gha 캐시).
2. **deploy** (VM `scatchlm.duckdns.org`, secret `NCP_SSH_KEY`):
   - VM 설정 파일을 **repo 기준으로 scp 동기화**: `docker-compose.prod.yml`, `Caddyfile`, `static/`. (이미지가 아니라 볼륨 마운트라 git이 single source of truth.)
   - `docker compose --env-file .env.prod pull app && up -d` → app은 새 이미지로 교체, Caddy는 설정 바뀌면 reload.
   - 헬스체크: `/docs`, `/privacy`, `/terms` (최대 10회 재시도).

**수동 개입이 필요한 두 가지 (CI가 안 함):**
- **`.env.prod`(시크릿)**: scp 동기화에서 의도적으로 제외 — VM `/opt/scatchlm/.env.prod`에서 수동 관리. 새 env 추가 시 직접 넣고 `up -d`로 재생성.
- **DB 마이그레이션(alembic)**: 워크플로가 자동 실행하지 **않음**. 모델 변경 배포 시 VM에서 수동: `ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T app alembic upgrade head'`

긴급 수동 배포(워크플로 우회)가 필요하면: 로컬 `docker build --platform linux/amd64 -t ghcr.io/joho54/scatchlm-app:latest backend/ && docker push ...` → VM `pull && up -d`.

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
