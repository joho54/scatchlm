새 git worktree를 생성하고 개발환경을 세팅해줘.

## 인자
- worktree 이름: $ARGUMENTS

## 절차

1. 이름이 비어있으면 사용자에게 이름을 요청
2. 새 브랜치와 worktree 생성:
   ```
   git worktree add ../scatchlm-$ARGUMENTS -b $ARGUMENTS
   ```
3. 생성된 worktree에서 개발환경을 symlink로 세팅 (빠른 초기화):
   - **Backend**: venv를 원본에서 symlink
     ```
     ln -s /Users/johyeonho/scatchlm/backend/venv ../scatchlm-$ARGUMENTS/backend/venv
     ```
   - **Mobile**: node_modules를 원본에서 symlink
     ```
     ln -s /Users/johyeonho/scatchlm/mobile/node_modules ../scatchlm-$ARGUMENTS/mobile/node_modules
     ```
   - 참고: Metro 0.83.3 (Expo SDK 54)은 symlink을 기본 지원하므로 별도 설정 불필요
4. `.env` 파일이 원본에 있으면 symlink:
   ```
   ln -s /Users/johyeonho/scatchlm/backend/.env ../scatchlm-$ARGUMENTS/backend/.env 2>/dev/null
   ln -s /Users/johyeonho/scatchlm/mobile/.env ../scatchlm-$ARGUMENTS/mobile/.env 2>/dev/null
   ```
5. 완료 후 worktree 경로와 브랜치명을 보고
