# Known Issues

## Guide cache는 response_language를 키에 포함하지 않음

**증상**
`GET /api/pdf/{id}/guide`, `GET /api/pdf/{id}/chapter-guide` 가 한 번 생성된 후에는 어떤 `response_language` 로 요청해도 처음 생성 시점의 언어로 된 캐시가 반환된다.

**원인**
`page_guides` 테이블의 UniqueConstraint가 `(textbook_id, page)` 뿐이다.
- 모델: `backend/app/models/guide.py:12`
- 페이지 가이드 조회/저장: `backend/app/routers/pdf.py:322-374`
- 챕터 가이드 조회/저장: `backend/app/routers/pdf.py:424-481` (page 컬럼을 `-chapter.page_start` 음수로 재활용)

캐시 도입 시 단일 언어를 가정했고, 이후 `response_language` 파라미터가 추가되면서 키 설계가 따라가지 못함.

**수정 시 필요한 작업**
1. `PageGuide` 모델에 `language` 컬럼 추가, UniqueConstraint를 `(textbook_id, page, language)` 로 변경.
2. Alembic 마이그레이션 생성 + 기존 row의 `language` 백필 (현재는 전부 한국어 가정 가능).
3. `routers/pdf.py` 의 두 캐시 조회/INSERT 지점에 `language` 필터/값 추가.
