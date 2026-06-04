# ScatchLM 배포 가이드 (Naver Cloud + DuckDNS)

## 현재 운영 정보

- **URL**: https://scatchlm.duckdns.org
- **VM**: NCP `server-scatchlm-1` (Ubuntu 24.04, s2-g3a, 2vCPU/8GB, 10GB root disk)
- **공인 IP**: `101.79.20.91`
- **SSH alias**: `scatchlm` (`User=root`, `IdentityFile=~/.ssh/id_ed25519`)
- **VPC/Subnet**: `scatchlm` / `scatchlm-subnet-public` (KR-1, Internet Gateway 전용)
- **운영 파일 위치**: `/opt/scatchlm/` (`docker-compose.prod.yml`, `Caddyfile`, `init.sql`, `.env.prod`)
- **이미지**: `ghcr.io/joho54/scatchlm-app:latest` (public)
- **Object Storage 버킷**: `scatchlm-prod` (KR, Private)

## 사전 작업 (수동)

### 1. DuckDNS 서브도메인 등록
1. https://www.duckdns.org 로그인 (GitHub/Google 등)
2. `subdomain` 입력란에 `scatchlm` (또는 원하는 이름) 입력 → **add domain**
3. 페이지 상단의 **token** 복사 (Caddy는 안 쓰지만 IP 갱신용으로 보관)
4. `current ip`에 NCP VM 공인 IP 입력 → **update ip**
   - 또는 VM에서 cron으로 자동 갱신:
     ```
     */5 * * * * curl -s "https://www.duckdns.org/update?domains=scatchlm&token=<TOKEN>&ip="
     ```

### 2. NCP 리소스
- **VPC + Subnet (Public)**: `scatchlm-vpc` / `scatchlm-subnet-public` (KR-1)
  - Subnet은 **Internet Gateway 전용 = Y (Public)** 으로 만들어야 공인 IP 부여 가능
- **Server (VM)**: Ubuntu 24.04, 2 vCPU/8GB
- **공인 IP**: Server 생성 후 **별도 신청 + 서버 연결**. Server 생성 마법사에서 같이 만들지 않으면 비공인 IP만 부여됨
- **ACG(방화벽)**: 인바운드 룰 — **80/443은 반드시 0.0.0.0/0 으로 열어야 함**. 안 열면 Let's Encrypt 검증 실패
  - 권장: 22(본인 IP/32), 80(0.0.0.0/0), 443(0.0.0.0/0). 기본 3389(RDP)는 삭제
- **Object Storage**: 콘솔 → Object Storage → 버킷 생성 (예: `scatchlm-prod`, KR, Private)
  - **서비스 이용 신청**이 선행돼야 함 (처음 진입 시 배너)
- **Container Registry**: GitHub Container Registry (ghcr.io) 사용. NCP 리소스 아님
  - NCP NCR는 사용 안 함 (Object Storage 의존성 활성화 quirk 회피)
- **API Authentication Key**: 마이페이지 → 인증키 관리 → Access Key/Secret Key 발급 (Object Storage용)
  - 현재 NCP는 IAM 통합 → `ncp_iam_*` 형식 키만 발급됨. 그래도 메인 계정 키면 Object Storage S3 API 동작
  - 서브 계정/IAM 사용자 키라면 Object Storage 정책 명시적 연결 필요

### SSH 키 등록 (NCP의 특이한 패턴)
NCP Ubuntu는 AWS와 달리 `.pem`을 SSH 키로 직접 쓰지 않는다.
1. 콘솔에서 **관리자 비밀번호 확인** → `.pem` 업로드 → 복호화된 root 비밀번호 표시
2. 그 비밀번호로 `ssh root@<IP>` 접속 (password 인증)
3. 들어가서 `~/.ssh/authorized_keys`에 본인 공개키 등록
4. 이후 키 인증으로 접속

로컬에서 한 방에:
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<VM_IP>
# 비밀번호 프롬프트에 NCP 관리자 비밀번호 입력
```

### SSH alias 등록
```bash
cat >> ~/.ssh/config << 'EOF'

Host scatchlm
    HostName scatchlm.duckdns.org
    User root
    IdentityFile ~/.ssh/id_ed25519
EOF
chmod 600 ~/.ssh/config
```

### 3. VM 초기 셋업 (Docker 공식 저장소 사용)
```bash
ssh scatchlm
apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
```

> Ubuntu 24.04 기본 저장소의 `docker.io`보다 공식 저장소가 compose v2 호환성이 좋다.

## 배포 순서

### A. 로컬(또는 CI)에서 이미지 빌드 + 푸시
VM에선 빌드 안 함. 빌드 캐시가 VM 디스크에 쌓이지 않도록 분리.

**사전 준비 (1회)**
1. GitHub → Settings → Developer settings → **Personal access tokens (classic)**
2. **Generate new token** → scope: `write:packages`, `read:packages`, `delete:packages`
3. 토큰을 안전한 곳에 저장
4. 로컬에서:
   ```bash
   echo <GITHUB_PAT> | docker login ghcr.io -u joho54 --password-stdin
   ```
5. **첫 푸시 후** https://github.com/users/joho54/packages 에서
   `scatchlm-app` 패키지 → **Package settings** → **Change visibility** → **Public**

**매 배포**
```bash
cd backend
docker build --platform linux/amd64 \
  -t ghcr.io/joho54/scatchlm-app:latest .
docker push ghcr.io/joho54/scatchlm-app:latest
```
> Mac(Apple Silicon)에서 빌드하면 `--platform linux/amd64` 필수. 안 그러면 VM에서 못 돌아감.

### B. VM에 설정 파일 배치
실제 배포에선 git clone 대신 **로컬에서 scp**로 4개 파일만 올린다 (시크릿 포함 `.env.prod`는 git 추적 X):

```bash
# 로컬에서
ssh scatchlm 'mkdir -p /opt/scatchlm'
scp backend/docker-compose.prod.yml backend/Caddyfile backend/init.sql backend/.env.prod \
    scatchlm:/opt/scatchlm/
ssh scatchlm 'chmod 600 /opt/scatchlm/.env.prod'
```

### C. VM에서 pull + 기동
```bash
ssh scatchlm
cd /opt/scatchlm

# 이미지 pull + 기동 (Caddy가 자동으로 Let's Encrypt 인증서 발급)
# 패키지가 Public이면 ghcr.io 로그인 불필요
docker compose -f docker-compose.prod.yml --env-file .env.prod pull
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d

# 로그 확인 (반드시 --env-file 같이)
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f app
docker compose -f docker-compose.prod.yml --env-file .env.prod logs caddy

# 헬스체크
curl https://scatchlm.duckdns.org/docs
```

> **주의**: 모든 `docker compose` 명령에 `--env-file .env.prod` 필수. 빼면 `${APP_IMAGE}`/`${DOMAIN}` 해석 실패로 명령이 거부됨.

## 운영

### 업데이트
```bash
# 로컬: 새 이미지 푸시
docker build --platform linux/amd64 -t ghcr.io/joho54/scatchlm-app:latest backend/
docker push ghcr.io/joho54/scatchlm-app:latest

# VM: pull + 재기동
ssh scatchlm
cd /opt/scatchlm
docker compose -f docker-compose.prod.yml --env-file .env.prod pull app
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d app
```
Alembic 마이그레이션은 컨테이너 시작 시 `alembic upgrade head`로 자동 실행됨.

### 설정 파일만 갱신 (compose / Caddy)
이미지 재빌드 없이 compose/Caddy 설정만 바뀐 경우:
```bash
scp backend/docker-compose.prod.yml backend/Caddyfile scatchlm:/opt/scatchlm/
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod up -d'
# Caddy만 재기동: ... restart caddy
```

### 이미지 정리 (디스크 관리)
```bash
docker image prune -af   # 사용 안 하는 이미지 삭제
```

### 백업 / 복구 (data-durability-spec)

> 상세 근거·트레이드오프: `docs/data-durability-spec.md`. 여기엔 운영 절차만 둔다.
> **VM 유실 시 user 데이터 복원 경로는 버킷의 pg_dump 덤프뿐**이다(pgdata는 VM 로컬 볼륨).

#### 자동 백업 (일배치 cron — `scripts/backup_db.sh`)

`pg_dump -Fc`(MVCC 스냅샷, 실행 중에도 일관 사본)를 **스트림으로** NCP Object Storage에
올린다. VM 디스크엔 덤프를 남기지 않는다(루트 9.8G 경쟁 회피). 자격증명은 `.env.prod`의
`OBJECT_STORAGE_*` 재사용. 업로더(`scripts/upload_stream.py`)는 app 이미지에 동봉(`COPY . .`).

VM 설치(수동, 1회):
```bash
# 스크립트는 app 이미지엔 들어가지만 cron 셸은 VM에 직접 배치
scp backend/scripts/backup_db.sh backend/scripts/prune_app_logs.sh backend/scripts/restore_db.sh \
    scatchlm:/opt/scatchlm/scripts/
ssh scatchlm 'chmod +x /opt/scatchlm/scripts/*.sh'
# crontab 등록 (매일 03:17, app_logs prune 주1회)
ssh scatchlm 'crontab -l 2>/dev/null; echo "17 3 * * * /opt/scatchlm/scripts/backup_db.sh >> /var/log/scatchlm-backup.log 2>&1"; echo "23 4 * * 0 /opt/scatchlm/scripts/prune_app_logs.sh >> /var/log/scatchlm-prune.log 2>&1"' # 그 뒤 crontab -e로 확정
# 수동 1회 검증
ssh scatchlm 'bash /opt/scatchlm/scripts/backup_db.sh'
```

> **보존(retention)** 은 스크립트가 아니라 **버킷 lifecycle 규칙**으로 관리(§A.3, 일14/주8 초안).
> NCP Object Storage 콘솔에서 `backups/db/` prefix에 만료 규칙을 설정한다(아직 미설정 — 수동 TODO).

#### 복구 (`scripts/restore_db.sh`)

**동일 VM 롤백:**
```bash
ssh scatchlm 'bash /opt/scatchlm/scripts/restore_db.sh --from-bucket 2026-06-04'
```
**VM 통째 유실 시:** 새 VM 프로비저닝 → `.env.prod` 배치(§시크릿 보관) → compose 기동(빈 pgdata)
→ `restore_db.sh --from-bucket <DATE>` → app 재연결. **진짜 자산은 버킷의 덤프, VM은 일회용.**

> **pgvector 함정**: 복원 대상에 `CREATE EXTENSION vector`가 선행돼야 한다. `restore_db.sh`가
> 먼저 `CREATE EXTENSION IF NOT EXISTS vector`를 돌린다. **복구 드릴(§A.5)을 분기 1회 수행**해
> 스키마·row 수·소요시간을 검증할 것 — 안 돌려보면 사고 당일에 발견한다.

#### 복구 드릴 (§A.5) — 운영 DB 절대 미접촉, 로컬 격리 컨테이너에서

`restore_db.sh`는 `--clean --if-exists`로 대상을 DROP·재생성한다 → **운영엔 절대 드릴로 돌리지 말 것**.
드릴은 버킷 덤프를 **일회용 pgvector 컨테이너**에 복원해 검증하고 파기한다(재해 시 "새 박스 복원"과 동일).

```bash
# 1) 버킷 덤프를 로컬로 (VM app 컨테이너 boto3 경유 — 로컬엔 boto3 불필요)
ssh scatchlm "cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T app python3 -c \"
import os,sys,boto3
c=boto3.client('s3',endpoint_url=os.environ['OBJECT_STORAGE_ENDPOINT'],region_name=os.environ['OBJECT_STORAGE_REGION'],aws_access_key_id=os.environ['OBJECT_STORAGE_ACCESS_KEY'],aws_secret_access_key=os.environ['OBJECT_STORAGE_SECRET_KEY'])
c.download_fileobj(os.environ['OBJECT_STORAGE_BUCKET'],'backups/db/scatchlm-<DATE>.dump',sys.stdout.buffer)\"" > /tmp/drill.dump
# 2) 일회용 컨테이너 (포트 미노출, prod와 격리)
docker run -d --name scatchlm-drill -e POSTGRES_PASSWORD=drill pgvector/pgvector:pg17
until docker exec scatchlm-drill pg_isready -U postgres; do sleep 1; done
# 3) DB + pgvector 확장 선행 → 복원(소요시간 측정)
docker exec scatchlm-drill psql -U postgres -c "CREATE DATABASE scatchlm;"
docker exec scatchlm-drill psql -U postgres -d scatchlm -c "CREATE EXTENSION IF NOT EXISTS vector;"
time docker exec -i scatchlm-drill pg_restore -U postgres -d scatchlm --no-owner < /tmp/drill.dump
# 4) 검증: row 수를 prod(SELECT relname,n_live_tup FROM pg_stat_user_tables)와 대조
docker exec scatchlm-drill psql -U postgres -d scatchlm -c "ANALYZE; SELECT relname,n_live_tup FROM pg_stat_user_tables ORDER BY relname;"
# 5) 파기
docker rm -f scatchlm-drill && rm -f /tmp/drill.dump
```

> **드릴 기록 2026-06-04** (덤프 `scatchlm-2026-06-04.dump`, 3.2MB): 복원 exit 0·무에러, 15개
> 테이블 row 수 prod와 **완전 일치**(users 7 / chapters 2790 / document_chunks 772 / ai_response 169 …),
> `document_chunks.embedding = vector(512)` 정상 복원(확장 선행 필수 확인), `alembic_version=d4e5f6a7b8c9`,
> 소요 ~0.15s. **백업은 복원 가능함이 검증됨.** 다음 드릴: 분기 1회 권장.

#### `.env.prod` 시크릿 보관 (복구 전제)

`.env.prod`는 VM 로컬·git 제외라 **VM 유실 시 함께 사라지면 위 복구가 막힌다**. 시크릿
매니저(1Password 등)에 사본을 두되 **DB 덤프 버킷과 분리**(권한 경계). 새 VM 복구의 0단계 = `.env.prod` 확보.

Object Storage의 PDF 원본은 이미 버킷(`STORAGE_BACKEND=s3`)이라 별도 백업 불필요(버킷 durability).

### iOS Config
`ios-app/ScatchLM/Utilities/Config.swift`:
- **DEBUG**: `http://<devApiHost>:18000/api` — `UserDefaults["devApiHost"]`로 Mac LAN IP 주입 가능
- **RELEASE**: `https://scatchlm.duckdns.org/api`

iPad에 Release 빌드 설치:
```bash
cd ios-app
xcodegen generate
xcodebuild -project ScatchLM.xcodeproj -scheme ScatchLM -configuration Release \
  -destination 'id=00008103-000C65D43AEB001E' -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008103-000C65D43AEB001E \
  ~/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Release-iphoneos/ScatchLM.app
```

## 로그 / 모니터링

`/check-prod-logs` 슬래시 명령으로 SSH 경유 docker compose logs 조회. 상세는 `.claude/commands/check-prod-logs.md`.

- Caddy access log: Caddyfile에 `log { output stdout; format console }` 활성화돼 있음. 모든 요청이 caddy 로그에 떨어짐
- iOS FE 로그: `LogService`가 2초 주기로 `POST /api/dev/log/batch` → app 로그에 `[fe]` prefix로 기록
- 모든 로그 라인은 `[trace:<32hex> req:<id>]` prefix를 가짐(O7). iOS가 보낸 요청은 BE 로그 trace_id == iOS Sentry trace_id로 상관됨

## Sentry (에러·크래시 리포팅, O7)

스펙: `docs/sentry-introduction-spec.md`. 코드(Track A·B)는 DSN 없이도 컴파일·동작(SDK no-op).
아래는 **수동/운영 절차**(Track C)다.

### C-1. 프로젝트 생성·DSN 발급 (sentry.io 대시보드)
1. 조직 생성 후 프로젝트 2개:
   - `scatchlm-backend` (Platform: **Python / FastAPI**)
   - `scatchlm-ios` (Platform: **Apple / iOS (Cocoa)**)
2. 각 프로젝트 Settings → Client Keys (DSN)에서 DSN 복사. **DSN은 커밋 금지.**

### C-2. DSN 주입
- **백엔드**: `/opt/scatchlm/.env.prod`에 `SENTRY_DSN=<backend-dsn>` + `SENTRY_TRACES_SAMPLE_RATE=0.05` 추가 후 `docker compose ... up -d`로 재기동. (템플릿: `.env.prod.example`)
  - `GIT_SHA`가 실제 SHA로 주입돼야 release regression 추적이 의미 있음(G-2 체크리스트).
- **iOS**: DSN을 `project.yml` target settings의 `INFOPLIST_KEY_SENTRY_DSN` 또는 Info.plist `SENTRY_DSN` 키로 주입(빌드설정/xcconfig 권장, 커밋 금지). 임시 dev 검증은 `UserDefaults`의 `sentryDSN` 키로도 가능(`Config.sentryDSN` 우선순위 참고).

### C-3. dSYM 업로드 (iOS 심볼리케이션)
릴리스 빌드의 dSYM을 Sentry에 올려야 크래시가 함수명·라인으로 보인다. 현재 CI 자동화 없음 → 수동:
```bash
# Archive 후 dSYM 경로 확인 → 업로드
sentry-cli --auth-token <token> debug-files upload \
  --org <org> --project scatchlm-ios \
  ~/Library/Developer/Xcode/Archives/.../dSYMs
```
(향후 Xcode build phase 또는 fastlane으로 자동화)

### 검증
- BE: `SENTRY_DSN` 설정 후 의도적 5xx → 대시보드 이벤트 + `request_id`/`trace_id` tag + `release`/`environment`. 4xx(404)는 이벤트 안 생김. payload에 Authorization/이미지/본문 없음.
- iOS: 의도적 크래시(`fatalError`) → 재실행 시 크래시 이벤트(심볼리케이션). iOS 에러와 그 요청의 BE 에러가 동일 `trace_id`로 Trace 뷰에서 연결.
- DSN 빈 값에서도 모든 로그 라인에 `[trace:…]` 존재.

## 트러블슈팅 (실제로 겪었던 것들)

### Let's Encrypt 인증서 발급 실패 — `Timeout during connect`
ACG에 80/443 인바운드 룰이 없거나 적용 ACG가 다른 것. 콘솔에서:
- Server → 서버 상세 → 적용 ACG 확인
- 해당 ACG에 80/443 (0.0.0.0/0) 추가

### `permission_denied: token does not match expected scopes` (GHCR push)
PAT 종류/권한 문제:
- **Classic PAT만** GHCR write 지원. Fine-grained PAT는 거부됨
- scope: `write:packages`, `read:packages` 체크돼 있어야 함

### `error from registry: denied` (GHCR push)
`docker login ghcr.io -u <github-username> --password-stdin` 안 한 상태. 로그인 후 재시도.

### `error while interpolating services.app.image: required variable APP_IMAGE`
docker compose 명령에 `--env-file .env.prod`를 빠뜨림.

### `Caddy YAML: mapping values are not allowed in this context`
compose 파일에서 `image: ${APP_IMAGE:?...:...}` 처럼 값에 `:`이 포함되면 따옴표로 감싸야 함:
```yaml
image: "${APP_IMAGE:?APP_IMAGE env required}"
```

### NCP Object Storage `InvalidAccessKeyId`
원인 후보:
1. **버킷 미생성** — Object Storage 콘솔에서 명시적으로 만들어야 함
2. **서비스 이용 신청 안 함** — 처음 진입 시 배너로 신청
3. **서브 계정 키에 Object Storage 정책 미연결** — NCP IAM에서 정책 추가

진단:
```bash
ssh scatchlm 'cd /opt/scatchlm && docker compose -f docker-compose.prod.yml --env-file .env.prod exec -T app python3 -c "
import os, boto3
s3 = boto3.client(\"s3\",
    endpoint_url=os.environ[\"OBJECT_STORAGE_ENDPOINT\"],
    region_name=os.environ[\"OBJECT_STORAGE_REGION\"],
    aws_access_key_id=os.environ[\"OBJECT_STORAGE_ACCESS_KEY\"],
    aws_secret_access_key=os.environ[\"OBJECT_STORAGE_SECRET_KEY\"])
print(s3.list_buckets())
"'
```

### iOS PDF 업로드 침묵 실패
`fileImporter`의 콜백에서 `defer { url.stopAccessingSecurityScopedResource() }`가 `Task { ... }` 바깥에 있으면, 함수 즉시 리턴 → defer 실행 → Task가 파일 읽을 때 권한 없어 실패. **반드시 Task 내부에서 start/stop**.

### iPad 빌드: Developer Disk Image not mounted
iPad 잠금 해제 + "이 컴퓨터 신뢰" 탭. iOS 16+는 Settings → Privacy & Security → Developer Mode도 ON.

### iPad 빌드: `The app identifier ... cannot be registered`
Apple Developer Portal이 해당 bundle ID를 우리 팀에 등록 못 함. project.yml에서 `PRODUCT_BUNDLE_IDENTIFIER`를 다른 유니크 값으로 명시 지정 (예: 소문자 `com.joho54.scatchlm`) 후 `xcodegen generate`.

## NCP 특이점 메모

- **Object Storage lifecycle은 S3 표준 API로 안 됨** — `PutBucketLifecycleConfiguration`은
  `operation not supported`, 레거시 `PutBucketLifecycle`은 `MalformedXML`, `Get...`은 콘솔에서
  걸어도 `NoSuchLifecycleConfiguration`을 돌려준다(NCP가 S3 lifecycle 표면을 노출 안 함).
  → **lifecycle은 콘솔에서만 설정·확인**하고 CLI 검증은 포기한다. 보존 규칙 미작동의 실패
  모드는 양성(덤프 누적, 데이터 손실 아님)이라 치명적이지 않다. (2026-06-04: `scatchlm-prod`
  `backups/db/` 60일 만료를 콘솔에서 설정 — API로는 검증 불가)
- pgvector는 NCP Cloud DB for PostgreSQL이 미지원 → **컨테이너로 직접 운영**
- NCP Container Registry는 Object Storage 백엔드 + 콘솔 UI 활성화 quirk가 있어 GHCR로 우회
- `.pem`은 root 비밀번호 복호화용. SSH 키 자체가 아님
