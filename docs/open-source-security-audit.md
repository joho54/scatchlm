# 오픈소스 공개 전 보안 감사

> 목적: 이 레포를 public으로 공개해도 되는지 사실 기반으로 판정한다.
> 최초 감사: 2026-06-25 (커밋 `0385e2e` 기준, 전체 히스토리 374커밋).
> 감사자: Claude (자동 스캔) + 검토 필요.

## 한 줄 결론

**시크릿 누설은 없다** — 374커밋 전체 히스토리에 실제 키/토큰/비밀파일이 들어간 적 없음. 다만 **운영 인프라 지문(공인 IP·SSH·도메인)이 문서에 그대로 노출**돼 있어, 공개 전 정리 또는 의도적 수용 결정이 필요하다. 치명적 차단 사유(blocker)는 없음.

## 판정 요약

| # | 항목 | 등급 | 공개 전 조치 |
|---|------|------|------|
| 1 | git 히스토리 시크릿 파일 | ✅ 없음 | 불필요 |
| 2 | 코드/히스토리 내 실 API 키·JWT·개인키 | ✅ 없음 | 불필요 |
| 3 | Supabase **publishable** anon 키 하드코딩 | 🟡 설계상 공개키 | RLS 의존 확인 |
| 4 | 운영 인프라 지문 (공인 IP·SSH root·pem 경로) | 🟠 노출 | 결정 필요 |
| 5 | 개인 이메일 (`joho0504@gmail.com`) | 🟡 의도적 공개 | 수용 가능 |
| 6 | 미추적 작업트리 파일 (`mem7d.csv` 등) | 🟡 PII 없음 | 확인 후 커밋/제외 |

등급: ✅ 안전 · 🟡 경미(수용 가능) · 🟠 결정 필요 · 🔴 차단

---

## 상세

### 1. git 히스토리 시크릿 — ✅ 깨끗
- 전체 히스토리(`git log --all --diff-filter=A`)에서 `.env`/`.pem`/`.key`/`credential`/`id_*` 등 **비밀 파일이 추가된 이력 0건**.
- 추적되는 env 파일은 `backend/.env.prod.example` **하나뿐이며 전부 빈 placeholder**(`ANTHROPIC_API_KEY=`, `SUPABASE_SECRET_KEY=`, `OBJECT_STORAGE_SECRET_KEY=` 등 값 없음). `change-me-strong-password`가 유일한 더미.
- `.gitignore`가 `backend/.env`, `backend/.env.*`(단 `.env.prod.example` 예외), `*.pem *.p8 *.p12 *.key *.mobileprovision *.jks`를 차단 — 정책 정상.

### 2. 실 시크릿 값 패턴 — ✅ 없음
- 전체 히스토리 블롭을 `sk-ant-`, `AKIA…`, `eyJ…`(JWT), `-----BEGIN … PRIVATE`, `service_role`, `ghp_`, `xoxb-` 등으로 grep → **실제 시크릿 매치 0건**.
- 매치된 것은 전부 주석/문서 속 단어("Supabase **secret** 키", "voyage-3-lite") — 값이 아님.
- `SUPABASE_SECRET_KEY`(=service_role), Anthropic/Voyage 키, Object Storage 키, DuckDNS 토큰, Sentry DSN은 모두 **추적 안 되는 `.env.prod`(VM 로컬)에만** 존재. 코드/히스토리엔 없음.

### 3. Supabase publishable 키 — 🟡 설계상 공개
- `ios-app/.../Config.swift:44`, `android-app/.../build.gradle.kts:24-30`에 `supabaseAnonKey = "sb_publishable_…"` 하드코딩.
- 이건 **누설이 아님**: publishable(anon) 키는 클라이언트 배포용으로 설계됐고 이미 App Store/Play 바이너리에 들어가 있다. URL(`iuuhjgnlxzakdrsuobuh.supabase.co`)도 마찬가지로 모든 클라이언트가 가진 값.
- **단, 안전성은 RLS(Row Level Security) 적용에 100% 의존한다.** 공개 시 누구나 이 키로 Supabase에 붙을 수 있으므로, 모든 테이블 RLS 정책이 올바른지 공개 전 1회 점검 권장. service_role 키만 노출 안 되면 구조적 위험은 없음.

### 4. 운영 인프라 지문 — 🟠 결정 필요 (핵심 항목)
공개 레포가 그대로 노출하는 운영 정보:
- **공인 IP `101.79.20.91`** — `CLAUDE.md`, `backend/DEPLOY.md`, `.github/workflows/deploy.yml:81,93`
- **도메인 `scatchlm.duckdns.org`**, **SSH alias `scatchlm` (User=root)**, **`~/.ssh/id_ed25519`**, **pem 경로 `/Users/johyeonho/scatchlm-secret/…`** — `CLAUDE.md:184-187`, `DEPLOY.md`
- NCP Object Storage endpoint, GHCR 이미지 경로, 로컬 절대경로(`/Users/johyeonho/…`, username 노출) — `.claude/commands/*`

시크릿은 아니지만 **공격 표면을 그대로 떠먹여 주는 정보**(특히 root SSH 가능한 공인 IP). 선택지:
- **(A) 수용** — IP/도메인은 어차피 DNS·인증서로 공개되는 값. SSH는 키 기반(비밀번호 차단)이고 ACG가 22번을 본인 IP로 제한하므로 IP 노출만으로 침입 불가. 운영 강도(키 인증·방화벽)가 충분하면 그냥 공개해도 실질 위험은 낮음.
- **(B) 정리** — `CLAUDE.md`/`DEPLOY.md`에서 IP·SSH·pem 경로를 placeholder(`<VM_IP>`, `<ssh-alias>`)로 치환하고, `.claude/commands/`(개인 워크플로)는 공개에서 제외(`.gitignore` 또는 별도 레포).

> 권장: 최소한 **(A)를 명시적으로 수용**하되, ACG 22번이 본인 IP로 제한돼 있고 SSH 비밀번호 인증이 꺼져 있는지 공개 전 확인. 여유가 있으면 (B)로 지문 제거.

### 5. 개인 이메일 — 🟡 수용 가능
- `joho0504@gmail.com`이 `backend/static/privacy.html`·`terms.html`에 **의도적 공개**(개인정보 문의처) — 이미 앱스토어 공개 정보. 문제 없음.
- `.claude/commands/check-prod-logs.md`에 심사관/본인 제외용으로 등장 — 개인 워크플로 파일이므로 (B) 제외 시 함께 사라짐.

### 6. 미추적 작업트리 파일 — 🟡 확인 후 결정
공개 시 함께 올라갈 수 있는 untracked 파일:
- `mem7d.csv` — `sar` 메모리 통계(datetime, kbmemfree …)일 뿐 **PII·이메일 0건**. 안전하나 레포 자료로 부적절하면 제외 권장.
- `mem7d_viz.ipynb` — 위 csv 시각화 노트북. 출력 셀에 시크릿 없는지 1회 확인 후 결정.
- `.DS_Store` — `.gitignore`로 차단됨(추적 안 됨). OK.

---

## 공개 전 체크리스트

- [ ] (3) Supabase 전 테이블 RLS 정책 점검 — anon 키로 무단 접근 불가 확인
- [ ] (4) ACG 22번 = 본인 IP 제한 + SSH 비밀번호 인증 비활성 확인 → IP 노출 수용 or 문서에서 지문 제거
- [ ] (4) `.claude/commands/` 공개 포함 여부 결정 (개인 워크플로 → 제외 권장)
- [ ] (6) `mem7d.csv`/`mem7d_viz.ipynb` 공개 포함 여부 결정, 노트북 출력셀 확인
- [ ] LICENSE 파일 추가 (현재 없음 — 공개 시 라이선스 명시 필수)
- [ ] 공개 직전 `.env.prod`가 VM에만 있고 레포에 없는지 최종 재확인

## 재현 (재감사 방법)

```bash
# 히스토리 비밀 파일
git log --all --pretty=format: --name-only --diff-filter=A | sort -u \
  | grep -iE '\.env$|secret|\.pem|\.key$|id_ed25519' | grep -v 'example'
# 히스토리 시크릿 값
git grep -nIE 'sk-ant-|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{30,}\.|-----BEGIN .*PRIVATE|service_role' \
  $(git rev-list --all) -- ':!*venv*' ':!*node_modules*'
# 인프라 지문
git grep -nIE '101\.79\.20\.91|duckdns|id_ed25519|ncloudstorage'
```
