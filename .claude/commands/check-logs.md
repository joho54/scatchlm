# /check-logs - BE/FE 로그 확인

모든 로그는 `backend/logs/uvicorn.log` 한 곳에 파이프됨.

## 사용법

인자 없이 실행하면 최근 로그 20줄 표시. 인자로 필터를 지정 가능.

## 로그 확인 명령

### 전체 최근 로그
```bash
tail -30 /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | grep -v "GET /manifest"
```

### FE (iOS 앱) 로그만
```bash
grep "FE" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | tail -20
```

### 에러만
```bash
grep -E "ERROR|error|failed" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | grep "FE" | tail -10
```

### 피드백 관련
```bash
grep -E "feedback|chat response" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | tail -10
```

### RAG 검색
```bash
grep -E "RAG|Query rewrite|Chapter search|Page search" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | tail -10
```

### LLM 호출
```bash
grep "LLM response" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | tail -10
```

### 캔버스/노트
```bash
grep -E "\[canvas\]|\[note\]" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | grep "FE" | tail -10
```

### PDF
```bash
grep -E "\[pdf\]" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | grep "FE" | tail -10
```

## 로그 태그 체계

- `[fe]` — iOS 앱에서 LogService를 통해 전송된 로그
- `[app.routers.feedback]` — 피드백/채팅 API
- `[app.services.retrieval_service]` — RAG 검색
- `[app.services.feedback_service]` — LLM 호출
- `[app.routers.pdf]` — PDF/가이드 API

## Arguments
- `$ARGUMENTS`: 필터 키워드 (예: "feedback", "RAG", "error", "FE")

기본 동작: 인자가 있으면 해당 키워드로 grep, 없으면 최근 30줄 표시.

실행할 명령:
```bash
if [ -z "$ARGUMENTS" ]; then
  tail -30 /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | grep -v "GET /manifest"
else
  grep -i "$ARGUMENTS" /Users/johyeonho/scatchlm/backend/logs/uvicorn.log | tail -20
fi
```
