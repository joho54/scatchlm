worktree의 변경사항을 커밋하고, main에 머지한 뒤, worktree를 제거해줘.

## 인자
- worktree 이름: $ARGUMENTS

## 절차

1. 이름이 비어있으면 `git worktree list`를 보여주고 사용자에게 선택 요청
2. 대상 worktree 경로 확인: `../scatchlm-$ARGUMENTS`
3. 해당 worktree로 이동하여 상태 확인:
   ```
   cd ../scatchlm-$ARGUMENTS
   git status
   git diff
   ```
4. 커밋되지 않은 변경사항이 있으면:
   - 변경 내용을 요약하여 사용자에게 보여주기
   - 사용자 확인 후 커밋 생성
5. main 브랜치로 머지:
   ```
   cd /Users/johyeonho/scatchlm
   git merge $ARGUMENTS
   ```
   - 충돌 발생 시 사용자에게 보고하고 해결 방안 제시
6. 머지 성공 후 worktree 및 브랜치 제거:
   ```
   git worktree remove ../scatchlm-$ARGUMENTS
   git branch -d $ARGUMENTS
   ```
7. 최종 결과 보고 (머지된 커밋, 삭제된 worktree/브랜치)
