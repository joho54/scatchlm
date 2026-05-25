# 노트 동기화 TODO

## 현재 상태 (출시 전)

노트(notebook)는 **iOS 로컬 GRDB/SQLite에만 존재**한다. 백엔드에는 노트 모델도, CRUD 엔드포인트도 없다.

백엔드에 저장되는 것:
- 피드백 텍스트/메타 (`feedbacks`) — `note_id`는 클라이언트 식별자로만 기록
- 피드백 채팅 (`feedback_chats`)
- PDF 교재 + 임베딩 (`textbooks`, `documents`, `chapters`)
- 개발 로그 (`devlog`)

백엔드에 저장되지 않는 것:
- 노트 메타 (title, language, textbook 연결)
- 노트 페이지 PencilKit 드로잉
- 마지막 본 페이지, PDF 열림 상태 등

결과적으로:
- 앱 삭제 = 노트 전부 소실
- 기기 간 동기화 없음
- 백업은 iCloud 기기 백업에만 의존

## 왜 지금은 OK인가

아직 출시 전. 사용자 데이터 자체가 없어서 마이그레이션 비용 0. 동기화를 미리 만들면 가짜 요구사항으로 과설계될 위험이 크다.

## 출시 후 트리거 조건

다음 중 하나가 발생하면 다시 검토:

1. 사용자가 기기 2대(iPad + iPad 등)에서 같은 계정 사용 요구
2. "기기 바꿨더니 노트 사라짐" 류 클레임 1건이라도 발생
3. 실사용자 10명 이상 누적 — 데이터 손실 리스크가 운영 부담이 되는 시점

## 옵션 (트리거 시 검토)

### A. 풀스택 동기화 (BE 모델 + API + 양방향 sync)
- BE에 `notes`, `note_pages` 모델 추가
- `GET/POST/PUT/DELETE /api/notes`, `/api/notes/{id}/pages`
- 충돌 해결 정책 필요 (last-write-wins / updated_at 비교 / CRDT)
- 비용: 1~2주

### B. 로컬 export/import만 먼저 (저비용 타협안)
- SQLite dump 또는 JSON으로 노트 전체를 파일로 내보내고 가져오기
- iOS Files 앱 / AirDrop 경유
- 동기화는 아니지만 **데이터 손실 리스크는 거의 제거**
- 비용: 1~2시간

### C. 그대로 두기
- iCloud 기기 백업에만 의존
- 실사용자 늘기 전까지는 합리적

## 권장

출시 직후에는 C로 출발 → 트리거 발생 시 B를 먼저 붙이고 → 멀티 디바이스 요구가 명확해지면 A로 확장.
