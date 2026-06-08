# Known Issues

## 캔버스 필기 진동(jitter) — 18줄 후 펜 닿으면 좌표계 튐

**증상**
약 18줄 필기 후부터 펜이 닿는 순간 캔버스가 흔들림(줌인처럼 보이나 zoom=1.0 불변, 실제는 contentOffset teleport). 증상 시작 후 복구 안 됨. 펜 떼면 정상 복귀. 피드백 카드 무관.

**원인** (2026-06-08 실기기 재현으로 규명)
NoteView 전체가 필기 도중 재생성된다. 필기 autosave → `db.onWrite` → debounced sync →
`lastSyncedAt` 갱신 → `HomeView.onChange`가 `loadNotes()`로 `notes` @State 재할당 →
NavigationStack 루트 재렌더 → `.navigationDestination` 재평가 → 푸시된 NoteView가 @State
전소실로 재생성 → `canvasView`가 빈 인스턴스로 리셋 → `makeUIView` 재호출(contentH 1668·offset 0
리셋) = 화면 점프. contentOffset teleport는 증상이었다. **OS/프레임워크 탓 아님 — 우리 코드 피드백 루프.**

**상태**
🔧 **원인 규명·픽스 적용, 미검증.** HomeView에서 노트 열람 중(`path` 비어있지 않음) sync 발 리스트
재로드를 보류해 루트 재렌더 사슬을 차단. 실기기(`make reinstall-dev`) 재검증 전까지 "해결" 아님 —
18줄+ 필기로 진동 소멸 + `makeUIView`가 필기 중 안 찍힘을 app_logs로 확인해야 종결. 상세는
`docs/canvas-jitter-investigation.md` §0 참조.

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
