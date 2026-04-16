# ScatchLM

펜 드로잉 기반 외국어 학습 보조 모바일 앱. 손글씨 입력을 Claude Vision API로 인식하고, 피드백을 캔버스 위에 렌더링한다.

## 프로젝트 구조

```
scatchlm/
├── backend/          # FastAPI 백엔드
│   ├── app/
│   │   ├── core/     # config, auth (Supabase JWT 검증)
│   │   ├── models/   # SQLAlchemy 모델
│   │   ├── routers/  # API 엔드포인트 (feedback, pdf)
│   │   └── services/ # 비즈니스 로직
│   ├── tests/
│   └── uploads/      # PDF 업로드 저장소
├── mobile/           # React Native (Expo) 모바일 앱
│   ├── app/          # expo-router 페이지
│   └── src/
│       ├── components/
│       ├── hooks/
│       ├── services/  # API 클라이언트, Supabase
│       ├── stores/    # Zustand 상태 관리
│       └── types/
└── SPEC.md           # 전체 명세서
```

## 기술 스택

### Backend (Python)
- **프레임워크**: FastAPI + uvicorn
- **DB**: PostgreSQL + SQLAlchemy (async) + asyncpg
- **인증**: Supabase Auth (JWT 검증)
- **LLM**: anthropic Python SDK (Claude Vision API, async)
- **PDF**: PyMuPDF (fitz)
- **마이그레이션**: Alembic (async, autogenerate)
- **테스트**: pytest + pytest-asyncio

### Mobile (TypeScript)
- **프레임워크**: React Native (Expo SDK 54) + expo-router
- **드로잉**: @shopify/react-native-skia
- **상태관리**: Zustand
- **로컬DB**: expo-sqlite
- **인증**: @supabase/supabase-js
- **HTTP**: axios

## 개발 커맨드

### Backend
```bash
cd backend
source venv/bin/activate
uvicorn app.main:app --reload          # 개발 서버 (localhost:8000)
pytest                                  # 테스트 실행
pytest tests/test_auth.py -v           # 특정 테스트
```

### Mobile
```bash
cd mobile
metro                                    # Expo 개발 서버 (alias, 로그 → mobile/logs/metro.log)
npm run ios                             # iOS 시뮬레이터
npm run android                         # Android 에뮬레이터
```

- Metro 로그 파일: `mobile/logs/metro.log` — `console.log` 출력이 여기에 파이프됨 (`~/.zshrc` alias)

### DB 마이그레이션 (Alembic)

모델(`app/models/`) 변경 시 반드시 마이그레이션을 생성하고 적용할 것. 수동 ALTER TABLE 금지.

```bash
cd backend
source venv/bin/activate
alembic revision --autogenerate -m "설명"   # 마이그레이션 자동 생성
alembic upgrade head                        # DB에 적용
alembic current                             # 현재 revision 확인
alembic downgrade -1                        # 롤백
```

- `env.py`가 `app.core.config.settings.DATABASE_URL`을 사용하므로 `alembic.ini`에 DB URL 설정 불필요
- 새 모델 파일 추가 시 `alembic/env.py`에 import 추가 필요

## 코드 컨벤션

- Backend: Python 3.11+, async/await 패턴, Pydantic 모델로 요청/응답 정의
- Mobile: TypeScript strict, 함수형 컴포넌트, Zustand 스토어로 전역 상태 관리
- API 응답은 JSON 형식으로 통일
- 환경변수는 `.env` 파일로 관리 (커밋 금지)

## 주요 API 엔드포인트

- `POST /api/feedback` — 캔버스 이미지 → Claude Vision → 피드백 JSON
- `POST /api/pdf/upload` — 교재 PDF 업로드
- `GET /api/pdf/{id}/extract` — PDF 텍스트 추출 (페이지 범위 지정)

## 응답 원칙

- 회의주의적 시니어 엔지니어 태도로 대답할 것. 추측으로 행동하지 말고 확인 먼저.
- 문제 분석 시 아래 형식으로 응답:
  1. **문제 상황**: 관찰된 사실만 기술
  2. **예상 원인 후보**: 가능성 높은 순서대로 나열, 각각 근거 포함
  3. **다음 절차**: 원인을 좁히기 위한 구체적 행동

## 디버깅 행동지침

- 구현에 어려움을 겪을 때 사용자에게 사과하는 대신, 명세나 문제에 대한 합의에 먼저 도달한 후 표준적인 솔루션을 제공할 것.

## 참고

- 상세 명세는 `SPEC.md` 참조
- 인증은 Supabase Auth 사용 (backend에서 JWT 검증만 수행)
