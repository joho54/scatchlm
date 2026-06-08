# Known Issues

## 캔버스 필기 진동(jitter) — 18줄 후 펜 닿으면 좌표계 튐 ✅ 해결

**증상**
약 18줄 필기 후부터 펜이 닿는 순간 캔버스가 흔들림. 스크롤 깊이에 비례해 진폭 증가. 펜 떼면 복귀.

**원인** (2026-06-08 소거법 하니스로 확정)
PKCanvasView가 **큰 frame(bounds)**을 가지면 펜 입력 시 떨린다. 기존 코드는 `setContentHeight`에서
`canvas.frame = contentView.bounds`로 캔버스를 전체 높이(수천 pt)까지 키웠고, 그만큼 커진 시점
("18줄 후")부터 떨렸다. 소거법(`DebugCanvasView` 스텝1~7)으로 확정: 큰 bounds 단일 변수가 원인이고
확장 행위·demote·host 구조·@State 재렌더는 전부 무죄. (초기 가설 "NoteView 재생성 루프"는 별개의
부차 문제로 `6ce20ef`에서 이미 차단했으나 진동의 주원인은 아니었다.)

**해결** (커밋 `c5b2981`)
**windowed 캔버스** — PKCanvasView를 뷰포트 크기 윈도우로 유지. `setContentHeight`는 `contentView`/
`host.contentSize`/`canvas.contentSize`만 키우고 `canvas.frame`은 안 키운다. `updateCanvasWindow`가
보이는 슬라이스로만 `canvas.frame`/`contentOffset`을 배치(줌 s 반영). 카드·오버레이·종이는 contentView에
그대로라 무영향, 좌표계 불변(마이그레이션 없음). 실기기에서 떨림 소멸 + 줌/스크롤 ink 정확 확인.
회귀 가드: `testSetContentHeightExpandsViaContentSizeKeepsCanvasWindowed`(canvas.frame이 뷰포트 유지).

---

## PDF 업로드 — 클라우드(OneDrive 등) 미다운로드 파일 ENOENT

**증상**
클라우드 File Provider의 미다운로드 placeholder PDF를 교재로 업로드하면 `NSCocoaError 260 / POSIX 2 (No such file or directory)`로 실패. 운영 신규 사용자 이탈 1건의 원인.

**원인**
`APIClient.uploadFile`의 비조정 `Data(contentsOf:)`(`APIClient.swift:203`)가 미다운로드 파일의 materialize를 트리거하지 못함. security-scope는 정상 획득됨(권한 문제 아님).

**상태**
🔧 **수정됨, 미검증.** `UIDocumentPicker(asCopy:true)` 래퍼로 전환(커밋 `8ee9561`). 실기기 OneDrive 미다운로드 재현 A/B 검증 전까지 "고쳐짐" 아님(시뮬/로컬 재현 불가). 상세·검증 레시피는 `docs/pdf-upload-cloud-materialize-spec.md` 참조.

**연쇄 silent 실패 (함께 처리)**
- 업로드 실패 silent catch → `uploadError`+`.alert` (CreateNoteSheet `b443902`, NoteMetaSheet `8ee9561`).
- 빈 캔버스 피드백 silent return → 토스트 (커밋 `8bbc4c7`).

---

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
