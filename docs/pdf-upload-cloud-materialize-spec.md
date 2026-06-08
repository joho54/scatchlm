# PDF 업로드 클라우드 미다운로드 실패 픽스 + 연쇄 silent 실패 정리

> **Status:** Draft
> **Date:** 2026-06-08
> **Author:** (auto-generated)
> **Scope:** iOS 앱 단독 (backend `/pdf/upload` 변경 없음)

---

## 1. Background

### 1.1 운영 이력 / 발견 경위

2026-06-06~07, 운영 텔레메트리(`app_logs`)에서 관측된 **유일한 실관측 외부 신규 사용자 이탈** 케이스를 추적해 발견.

해당 사용자(`c9e3dcca…`, Apple private relay) 행동 시퀀스:
1. Apple 로그인 성공
2. **OneDrive에 있는 PDF**(`[교사용] [미래엔] 통합사회 1.pdf`)를 교재로 업로드 시도 → **실패**
3. 빈 노트 생성 (제목 "통합사회"는 사용자가 직접 입력, `hasPdf: false`)
4. 빈 캔버스에서 피드백 버튼을 두 세션에 걸쳐 7회 연타 → 매번 `no new strokes`
5. 이탈 (재방문 없음)

업로드 실패 로그 본문:
```
NSCocoaErrorDomain Code=260 "파일이 존재하지 않기 때문에 … 열 수 없습니다."
  → NSUnderlyingError NSPOSIXErrorDomain Code=2 "No such file or directory"
경로: …/File Provider Storage/item|1|85AFA33…/[교사용] [미래엔] 통합사회 1.pdf
로그 필드: { size: -1, securityScoped: true }
```

### 1.2 근본 원인 (코드 검증 — §6 참조)

**`APIClient.uploadFile`의 `Data(contentsOf:)`가 비조정(non-coordinated) 읽기**라, File Provider(OneDrive/iCloud/Google Drive 등)의 **미다운로드(unmaterialized) placeholder 파일**을 만나면 다운로드를 트리거하지 못하고 `ENOENT`로 즉시 실패한다.

증거 체인:
- `securityScoped: true` → security scope 획득은 정상 (권한 문제 아님)
- 그런데 `size: -1` → scope 잡힌 상태에서도 `fileSizeKey` 조차 못 읽음 = 바이트가 로컬에 없음
- 읽기는 비조정 `Data(contentsOf:)` → `ENOENT`

> ⚠️ **"미다운로드"는 정황상 강한 추론이며 100% 확정이 아니다.** `size: -1`의 다른 원인(일시적 stale 등)을 로그만으로 완전 배제하지 못했다. 단, 아래 픽스는 미다운로드/비조정 양쪽을 모두 덮으므로 원인을 100% 확정하지 않아도 올바른 해법이다. 확정은 §6.x 실기기 재현으로만 가능.

### 1.3 연쇄 silent 실패 (이탈을 완성시킨 구조)

세 개의 침묵이 겹쳐 신규 사용자를 길 잃게 만들었다:

| # | 침묵 지점 | 현재 동작 | 사용자 인지 |
|---|---|---|---|
| S1 | PDF 업로드 실패 | catch가 `uploading=false`만, **토스트 없음** | "왜 안 되지?" 단서 0 |
| S2 | 업로드 실패 후 노트 생성 | 교재 없이 그대로 생성 가능 (교재는 선택 항목) | 교재 붙은 줄 착각 가능 |
| S3 | 빈 캔버스 피드백 | silent return (`no new strokes`) | 버튼 먹통으로 인지 |

> **S3는 이미 처리됨** — 커밋 `8bbc4c7`(피드백 경로 3개 silent return → 토스트). 본 스펙에서는 참고로만 두고 재작업하지 않는다.

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| 피드백 경로 silent return | 커밋 `8bbc4c7`로 완료 |
| 캔버스 필기 진동 버그 | 별도 진단 진행 중 (커밋 `dc9e65c` 계측). 무관 |
| backend `/pdf/upload` 변경 | 서버는 multipart 바이트만 받음 — 변경 불필요 |
| 업로드 진행률 UI | 현 범위 밖 (asCopy 채택 시 시스템 피커가 자체 제공) |
| 대용량 PDF 스트리밍 업로드(메모리) | 별도 개선 — §7 Risk에만 기록 |

---

## 2. 현재 플로우

```
[새 PDF 업로드] 버튼
   │
   ▼
.fileImporter (SwiftUI)            ← asCopy 미지원, security-scoped URL 반환
   │  success(url)
   ▼
handleFileImport()
   │  url.startAccessingSecurityScopedResource()   ✅ 정상
   │  APIClient.uploadFile(url)
   │     └─ Data(contentsOf: url)   ← ❌ 비조정 읽기. 미다운로드면 ENOENT
   │  catch → appLogError + uploading=false   ← ❌ S1 silent
   ▼
(업로드 성공 시) textbooks.append + selectedTextbookId 설정
(실패 시) textbooks/selectedTextbookId 변화 없음 → 사용자는 무반응만 봄
   │
   ▼
[만들기] 버튼 → onCreate(title, language, selected=nil)   ← S2: 교재 없이 생성
```

두 진입점이 **동일 구조**를 공유한다:
- `CreateNoteSheet` (새 노트 생성 시 교재 첨부)
- `NoteMetaSheet` (기존 노트 메타 수정 시 교재 첨부)

---

## 3. Backend API Inventory

iOS 단독 변경. 신규/변경 backend 엔드포인트 없음 — **API 계약 동결 단계 N/A.**

| Method | Path | 설명 | 상태 |
|---|---|---|---|
| POST | `/pdf/upload` | multipart PDF 업로드 | **변경없음** |
| GET | `/pdf/textbooks` | 교재 목록 | 변경없음 |

서버는 클라이언트가 보내는 multipart 바이트만 처리하므로, 클라이언트가 파일을 올바르게 읽어 보내기만 하면 된다.

---

## 4. 구현 설계

### 4.1 근본 픽스 — 두 후보 (택1)

#### 후보 A (권장): `UIDocumentPicker(asCopy: true)` 래퍼로 전환

- 시스템 피커가 파일을 **다운로드 + 앱 샌드박스로 복사**한 뒤 로컬 사본 URL을 반환.
- 결과: security-scope 불필요, materialize 보장, 대용량 다운로드 진행은 시스템 피커가 표시.
- SwiftUI `.fileImporter`는 `asCopy` 미지원 → **`UIViewControllerRepresentable`로 `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:true)` 래퍼 신설**, 두 시트의 `.fileImporter`를 교체.
- `APIClient.uploadFile`의 `Data(contentsOf:)`는 로컬 사본이라 **그대로 동작**(추가로 §4.1 B를 belt-and-suspenders로 병행 가능).

**장점:** 재현 불가한 클라우드 엣지를 *구조적으로* 제거(로컬 파일이면 무조건 성공). 시스템이 다운로드 진행/실패 UI 제공.
**단점:** 변경 범위가 큼(래퍼 신설 + 두 시트 교체). 임시 사본 디스크 사용.

#### 후보 B: `NSFileCoordinator` coordinated read

- `APIClient.uploadFile` 한 곳만 수정. 읽기 직전 coordinated read(`.forUploading`)로 provider에 materialize 강제.
- 피커(`.fileImporter`)는 그대로.

```swift
var coordError: NSError?
var readError: Error?
var fileData: Data?
NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [.forUploading], error: &coordError) { readURL in
    do { fileData = try Data(contentsOf: readURL) } catch { readError = error }
}
if let e = coordError { throw e }
if let e = readError { throw e }
guard let data = fileData else { throw APIError.fileUnreadable }
```

**장점:** 변경 범위 최소(1개 함수). Apple 문서가 보장하는 정식 in-place 읽기.
**단점:** 피커는 placeholder URL을 계속 다룸 → 검증을 "믿어야" 함(개발자가 재현 어려움). 다운로드 진행 UI 없음(조용히 블로킹).

**결정 권장:** **후보 A.** 개발자가 클라우드 미다운로드 엣지를 재현/검증하기 어려운 상황이므로, "로컬 사본 보장"이라는 구조적 안전이 더 가치 있다. 단 변경 범위가 부담되면 후보 B로 시작해 1차 출시 → 효과 관측 후 A 검토도 가능. (이 결정은 §6.x 재현 결과와 무관하게 사전 확정 가능.)

> ⚠️ 어느 후보든 **다운로드 강제 ≠ 무조건 성공.** 오프라인/파일 삭제 시 여전히 실패한다. 그 실패를 §4.2 토스트로 전달하는 것이 한 세트.

### 4.2 업로드 실패 UX (S1)

두 시트 모두:
- `catch` 블록에 사용자 안내 추가 (현재 `appLogError` + `uploading=false`만).
- picker `.failure` case도 안내 추가 (현재 `return`만).

문제: **두 시트는 `Form` 기반 sheet라 `NoteView.showToast` 같은 토스트 인프라가 없다.** 설계 선택:
- (권장) `.alert` 사용 — `@State private var uploadError: String?` + `.alert(item:)`/`isPresented`. 사용자가 명시적으로 확인하므로 깜빡임 없음.
- 또는 시트 상단 인라인 에러 텍스트.

문구 예: `"PDF를 불러오지 못했어요. 네트워크를 확인하거나, 기기에 저장된 파일을 선택해 주세요."`
(에러 종류 구분 가능하면 — ENOENT/네트워크 = 위 문구, 그 외 = 일반 재시도 문구.)

### 4.3 노트 생성 흐름 (S2) — 정정

당초 "업로드 실패 시 노트 생성 차단"을 검토했으나, **코드 검증 결과 교재는 명시적 선택 항목**(`CreateNoteSheet.swift:42` `"교재 (선택)"`)이고 교재 없는 노트는 정상 경로다. 제목도 자동 추출이 아니라 사용자 입력(`handleFileImport`이 title 미변경)이다.

→ **별도 게이트 불필요.** §4.2 토스트로 "업로드가 실패했다"가 명확해지면, 사용자는 교재가 안 붙었음을 인지하고 스스로 판단(재시도 / 교재 없이 생성)할 수 있다. S2는 **S1 수정으로 해소**된다.

(선택적 보강 — 과하지 않은 선에서) 업로드 실패 직후 `selectedTextbookId == nil`인 상태로 "만들기"를 누르면 "교재 없이 만들까요?" 확인을 띄우는 것도 가능하나, 교재 없는 노트가 흔한 정상 흐름이라 마찰만 늘 수 있어 **기본 비채택**. 필요 시 후속.

---

## 5. 구현 단계 (Tracks)

> 규모: **1인 작업.** 아래 "트랙"은 병렬 분할이라기보다 **권장 구현 순서**다. 후보 A 채택 시 A·B가 같은 파일(두 시트)을 건드리므로 병렬이 아니라 순차가 자연스럽다.

```
시작
 ├─ Track A: 근본 읽기 픽스 (후보 A 또는 B)
 ├─ Track B: 업로드 실패 UX (alert) — 두 시트 + picker .failure
 └─ Track C: (선택) 노트 생성 확인 — 기본 비채택
        │
        ▼
   Track V: 실기기 OneDrive 재현 검증 (A·B 완료 후, 필수)
```

**의존성:**
- 후보 A 선택 시: Track A와 B가 **동일 파일(두 시트)** 수정 → 같은 작업자가 순차로. (A에서 picker 교체 → B에서 실패 alert 추가)
- 후보 B 선택 시: Track A(`APIClient.uploadFile`)와 Track B(두 시트)는 **다른 파일** → 병렬 가능.
- Track V는 A·B 완료가 전제.

**인원별 배분:**

| 인원 | 배분 |
|---|---|
| 1명 | A → B → (C 생략) → V. 전부 순차 |
| 2명 | (후보 B 한정) 1명 A(APIClient), 1명 B(두 시트 alert). 합류 후 함께 V |

### Track A: 근본 읽기 픽스
**의존:** 없음
**작업량:** 후보 A = 중간 / 후보 B = 작음
**가장 복잡한 부분:** (A) `UIDocumentPicker` 래퍼의 delegate·dismiss·취소 처리, 두 시트의 `.fileImporter` → 래퍼 교체

| ID | 파일 | 내용 |
|---|---|---|
| A-1(B안) | `ios-app/ScatchLM/Services/APIClient.swift` (~203) | `Data(contentsOf:)` → `NSFileCoordinator` coordinated read(`.forUploading`) + 실패 시 throw |
| A-1(A안) | `ios-app/ScatchLM/Views/` (신규 `DocumentPicker.swift`) | `UIViewControllerRepresentable` + `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:true)` 래퍼. delegate로 URL/취소/에러 콜백 |
| A-2(A안) | `CreateNoteSheet.swift` (126), `NoteMetaSheet.swift` (168) | `.fileImporter` → 신규 래퍼로 교체. 핸들러는 로컬 사본 URL 사용(scope dance 제거 가능) |

### Track B: 업로드 실패 UX
**의존:** 후보 A 시 A 완료 후(같은 파일) / 후보 B 시 없음
**작업량:** 작음

| ID | 파일 | 내용 |
|---|---|---|
| B-1 | `CreateNoteSheet.swift` (`handleFileImport` 160-227) | catch + `.failure` case에 `@State uploadError` 설정, `.alert` 부착 |
| B-2 | `NoteMetaSheet.swift` (`handleFileImport` 201-244) | 동일 |
| B-3 | (선택) `APIClient.swift` | `APIError`에 `fileUnreadable` 케이스 + `LocalizedError` 문구(에러 구분 토스트용) |

### Track C: 노트 생성 확인 (선택, 기본 비채택)
§4.3 참조. 기본 구현 안 함. 필요 시 `CreateNoteSheet.swift:107` "만들기" 버튼에 조건부 confirm.

### Track V: 실기기 재현 검증 (필수)
§6.x 레시피대로. 시뮬/로컬 파일로는 재현 불가 — 반드시 실기기 + 클라우드 미다운로드 상태.

---

## 6. 확인 완료 사항 (코드 검증)

| # | 확인 내용 | 근거 |
|---|---|---|
| 1 | 비조정 읽기가 실패 지점 | `APIClient.swift:203` `let fileData = try Data(contentsOf: fileURL)` |
| 2 | security scope는 정상 획득(권한 문제 아님) | `CreateNoteSheet.swift:181` `startAccessingSecurityScopedResource()`, 로그 `securityScoped: true` |
| 3 | 업로드 실패 catch가 silent (S1) | `CreateNoteSheet.swift:221-224`, `NoteMetaSheet.swift:238-241` — `appLogError` + `uploading=false`만 |
| 4 | picker `.failure` case도 silent | `CreateNoteSheet.swift:164-166`, `NoteMetaSheet.swift:203-205` — `return`만 |
| 5 | 교재는 선택 항목, 교재 없는 노트는 정상 | `CreateNoteSheet.swift:42` `Section("교재 (선택)")`, `:108-117` `selected` nil 허용 |
| 6 | 제목은 사용자 입력(자동 추출 아님) | `handleFileImport`(158-227)이 `title` 미변경. `Note.resolveTitle(title, textbookName: selected?.fileName)` `:114` |
| 7 | 두 시트가 동일 `uploadFile` 공유 | `CreateNoteSheet.swift:204`, `NoteMetaSheet.swift:225` 모두 `APIClient.shared.uploadFile("/pdf/upload", fileURL:)` |
| 8 | S3(피드백 silent)는 이미 처리 | 커밋 `8bbc4c7`, `NoteView.swift` requestFeedback 3개 guard |

### 6.x 미확인 항목 (실기기 재현 필요)

| # | 항목 | 확인 방법 |
|---|---|---|
| R1 | 실패 원인이 "미다운로드"인지 확정 | 실기기에서 OneDrive 미다운로드 PDF로 **픽스 전** 빌드 → 동일 `ENOENT` 재현되는지 |
| R2 | 픽스가 실제로 해결하는지 | **픽스 후** 빌드 → 같은 미다운로드 파일 업로드 성공하는지 |
| R3 | 다운로드 끝내 실패 시 UX | 기내 모드 등으로 다운로드 불가 상태 → §4.2 alert가 뜨는지 |
| R4 | 후보 B 채택 시 OneDrive에서 coordinated read가 실제 materialize 트리거하는지 | R2와 동일 절차로 확인 |

**재현 레시피 (R1~R3):**
1. iPad/iPhone 파일 앱 → OneDrive 로그인, 큰 PDF 준비
2. 파일 앱에서 해당 파일 길게 눌러 **"다운로드 항목 제거"** → placeholder(미다운로드) 상태로 만듦
3. (픽스 전 빌드) 앱에서 그 파일을 교재 업로드 → **ENOENT 재현 확인** (R1)
4. (픽스 후 빌드) 동일 절차 → **성공 확인** (R2)
5. (R3) 2번 상태 + 기내 모드 ON → 업로드 → **실패 alert 확인**

> CLAUDE.md 응답 원칙: 실기기에서 R1~R3를 직접 확인하기 전엔 "고쳐졌다"고 선언하지 않는다. 시뮬레이터/빌드 성공은 검증이 아니다.

---

## 7. Risk

| Risk | Impact | Mitigation |
|---|---|---|
| 후보 A 래퍼의 취소/에러 경로 누락 | 피커 취소 시 hang/무반응 | delegate `documentPickerWasCancelled` 처리, 취소도 `uploading=false`로 복귀 |
| 후보 B가 OneDrive에서 materialize를 트리거 못 할 가능성 | 픽스했는데 여전히 실패 | R4 실기기 확인 필수. 안 되면 후보 A로 전환 |
| 대용량 PDF를 `Data`로 전부 메모리 적재 | 큰 교재(수백 MB)에서 메모리 압박 | 현 범위 밖. 후속으로 temp 파일 스트리밍 업로드 검토(§1.4) |
| `.alert` 문구가 원인과 안 맞음(네트워크 vs 파일없음 vs 권한) | 사용자 오안내 | B-3로 `APIError` 구분 후 문구 분기. 최소한 일반 재시도 문구는 보장 |
| 재현 환경 미확보로 검증 못 함 | "고쳤다" 단정 불가 | §6.x 레시피로 실기기 재현 선확보. 못 하면 미검증으로 명시 보고 |

---

## 부록: 관련 커밋
- `8bbc4c7` — 피드백 경로 silent return → 토스트 (S3, 완료)
- `dc9e65c` — 캔버스 진동 진단 계측 (무관, 진행 중)
