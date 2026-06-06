새 git worktree를 생성하고, **세션을 그 워크트리로 전환**한 뒤 개발환경을 세팅해줘.

## 인자
- worktree 이름: $ARGUMENTS

## 절차

1. 이름이 비어있으면 사용자에게 이름을 요청.

2. 새 브랜치와 worktree 생성 (메인 저장소 CWD에서 실행):
   ```
   git worktree add ../scatchlm-$ARGUMENTS -b $ARGUMENTS
   ```

3. **세션을 워크트리로 바인딩** — 이 단계가 핵심이다. `git worktree add`는 디렉토리만
   만들 뿐 세션 CWD는 메인에 남으므로, 반드시 `EnterWorktree` 툴로 세션을 워크트리로
   전환한다. 이걸 빠뜨리면 이후 Edit/Write가 절대경로라 메인 저장소에 작업이 들어간다.
   ```
   EnterWorktree(path: "/Users/johyeonho/scatchlm-$ARGUMENTS")
   ```
   - 전환 후에는 CWD가 `/Users/johyeonho/scatchlm-$ARGUMENTS`가 된다.
   - 이후 **모든 파일/명령 작업은 이 워크트리 경로 기준**으로 수행하고,
     메인 저장소(`/Users/johyeonho/scatchlm`)는 절대 건드리지 않는다.
   - 작업 종료/이동은 `ExitWorktree` 또는 `/collect-worktree`로 처리.

4. 개발환경을 symlink로 세팅 (빠른 초기화). 타깃·소스 모두 절대경로로 지정하므로
   CWD 전환과 무관하게 동작한다:
   - **Backend**: venv를 원본에서 symlink
     ```
     ln -s /Users/johyeonho/scatchlm/backend/venv /Users/johyeonho/scatchlm-$ARGUMENTS/backend/venv
     ```
   - **Mobile**: node_modules를 원본에서 symlink
     ```
     ln -s /Users/johyeonho/scatchlm/mobile/node_modules /Users/johyeonho/scatchlm-$ARGUMENTS/mobile/node_modules
     ```
   - 참고: Metro 0.83.3 (Expo SDK 54)은 symlink을 기본 지원하므로 별도 설정 불필요.

5. `.env` 파일이 원본에 있으면 symlink:
   ```
   ln -s /Users/johyeonho/scatchlm/backend/.env /Users/johyeonho/scatchlm-$ARGUMENTS/backend/.env 2>/dev/null
   ln -s /Users/johyeonho/scatchlm/mobile/.env /Users/johyeonho/scatchlm-$ARGUMENTS/mobile/.env 2>/dev/null
   ```

6. 완료 후 worktree 경로·브랜치명, 그리고 **"세션이 이 워크트리로 전환됨"**을 사용자에게
   보고. 이후 들어오는 작업(예: `/goal`, 기능 구현)은 모두 이 워크트리에서 수행한다.
