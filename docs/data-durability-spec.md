# Postgres 데이터 영속화 & 백업 Spec

> **Status:** 코드 구현 완료 (2026-06-04) — VM/NCP 콘솔/시크릿 매니저 수동 작업만 잔존(체크리스트 ⏳)
> **Date:** 2026-06-04
> **Author:** (auto-generated)

단일 VM 토폴로지에서 Postgres 데이터를 **(A) VM 유실로부터 지키고(백업/복구)**,
**(B) 활동 로그를 휘발성 json-log에서 DB로 영속화**하는 두 작업을 한 문서로 묶는다. 둘 다
같은 Postgres·같은 VM durability 스토리를 공유하므로 배경을 공통으로 둔다.

> **우선순위:** **Part A(백업) > Part B(로그 적재).** A는 product 데이터의 비가역 소실을 막는
> 일이고, B는 관측 가역 문제다. B가 취소돼도 A는 단독으로 최우선 진행한다.

---

## 1. 공통 배경

### 1.1 토폴로지 / 운영 실측 (2026-06-04)

| 점검 | 결과 |
|---|---|
| 스택 | app·postgres·caddy가 **단일 VM** docker compose 스택. 매니지드 DB 아님 |
| `pgdata` 위치 | `Driver: local`, `/var/lib/docker/volumes/scatchlm-prod_pgdata/_data` — **VM 로컬 블록 볼륨** |
| postgres 컨테이너 | Up 10일 — 배포는 app만 재생성, postgres는 미접촉 |
| app 컨테이너 | Up 18h — `backend/**` 배포 때마다 재생성 |
| 자동 백업 | **없음** — crontab·systemd timer 모두 없음. `/check-prod-db backup`은 순수 수동 |
| `STORAGE_BACKEND` | `s3` (NCP Object Storage, 버킷 `scatchlm-prod`) |
| `uploads` 로컬 볼륨 | 8.0K(빈 `pdf/` 하나) — 로컬 폴백 미사용 |
| 루트 디스크 | 9.8G 중 2.9G 여유(69% 사용) — DB·로그가 동거 |

### 1.2 영속 자산 분석 — VM 디스크에서 무엇을 지켜야 하나

"오만 게 섞인 VM 디스크"에서 **장기 영속이 실제로 필요한 자산은 단 하나(Postgres)**다.

| 자산 | 위치 | 재생성 가능? | 영속 백업 필요 |
|---|---|---|---|
| **Postgres `pgdata`** (user·노트·피드백·교재 메타·`app_logs`) | VM 로컬 볼륨 | ❌ | **필수 — 본 스펙** |
| 교재 PDF 원본 | **이미 Object Storage**(`STORAGE_BACKEND=s3`) | 이미 오프박스 | 불필요(버킷 durability) |
| 앱 코드/이미지 | ghcr 이미지 | ✅ 배포로 복원 | 불필요 |
| Caddy 인증서 | `caddy_data` 볼륨 | ✅ Let's Encrypt 재발급 | 불필요 |
| json-log | 컨테이너 로컬 | ✅ 휘발 OK(→ Part B로 DB 이관) | 불필요 |
| `.env.prod`(시크릿) | VM 로컬 파일, git 제외 | ⚠️ 분실 시 재구성 | **백업 아님 — 시크릿 보관(§A.6)** |

#### 1.2.1 "PDF가 s3니 DB도 이미 영속"이라는 오해 정정

PDF가 버킷에 있는 것과 **Postgres가 버킷을 쓰는 것은 전혀 다른 얘기**다. 못박는다:

- **s3를 쓰는 주체는 앱 코드(`storage.py`)** 가 PDF를 올릴 때뿐이다.
- **Postgres 자신은 `pgdata`를 VM 로컬 블록 디스크에 쓴다**(실측 `Driver: local`). 버킷이 아니다.
- **Postgres는 구조적으로 Object Storage를 데이터 디렉터리로 쓸 수 없다:** Postgres는 데이터
  디렉터리에 **POSIX 블록 파일시스템**(`fsync`·in-place 랜덤 라이트·파일 락·mmap)을 요구하는데,
  Object Storage(S3)는 `PUT`/`GET` 단위 불변 객체로 부분 수정·fsync·락이 없다. → `pgdata`를
  버킷에 두는 방법은 **존재하지 않는다.** 버킷에 둘 수 있는 건 *데이터 파일*이 아니라
  *백업(pg_dump 산출물)* 뿐이다.

**결론:** PDF는 *원본이 이미 금고(버킷)에 있는* 것, Postgres 데이터는 *책상 위(로컬 디스크)에
있어 사진 찍어 금고에 넣어야(pg_dump→버킷)* 하는 것. PDF 바이트가 s3에 있어도 그
**메타데이터·user·노트·피드백·`app_logs`는 전부 VM 로컬 Postgres = 백업 대상.**

### 1.3 인스턴스 분리·매니지드 DB는 시기상조 (강한 합의)

- 분리/매니지드가 사는 것: **장애 격리·독립 스케일·백업 운영 아웃소싱.** 현재 트래픽(24h 4
  사용자)에서 셋 다 불필요하고 운영 복잡도·요금만 선청구.
- **매니지드 DB가 없애는 것은 "백업"이 아니라 "백업 운영"이다.** provider가 스냅샷·PITR·보존을
  자동으로 굴려줄 뿐, 백업이라는 작업·비용 자체가 사라지지 않고(요금에 포함), **복구 검증은
  매니지드에서도 우리 몫으로 남는다**(§A.5).
- → 백업은 어느 쪽이든 필수. 차이는 *우리가 운영하느냐 / provider가 운영하느냐*뿐. **지금
  규모엔 자가 백업(cron 한 줄 + 비용 ≈0)이 합리적 선택.**
- **전환 트리거**(실측으로 관찰될 때만 재검토): (a) postgres가 app과 CPU/메모리를 경쟁해 병목,
  (b) app 수평 확장 필요. **"백업이 귀찮아서"는 트리거가 아니다.**

---

# Part A — DB 백업/복구 (실질 최우선)

## A.1 왜 — VM 유실 시 복원 경로 0 (비가역)

위험을 가역성으로 등급화하면:

| 시나리오 | 현재 대비책 | 결과 | 등급 |
|---|---|---|---|
| **VM/볼륨 유실, 복원 경로 없음** | **없음** | user 데이터 영구 소실, 복구 불가 | **치명(비가역)** |
| 배포 시 로그 리셋 | 없음(→ Part B) | 관측 공백 | 중(가역) |
| 디스크 풀 | 없음(→ B Track C/D) | app 다운 | 중(가역, 재기동) |

우선순위는 *발생 확률*이 아니라 **확률 × 비가역성**으로 매긴다. VM 유실은 확률이 낮아도(연
단위) **비가역성이 최대**라 기대손실이 가장 크다 → 데이터 안전의 실질 최우선.

## A.2 백업 방식: 논리 백업(pg_dump) — 디스크/볼륨 스냅샷 아님

- **실행 중 `pgdata`를 raw 복사하면 깨진다**(torn write). 일관 사본엔 postgres 정지(다운타임)
  또는 `pg_basebackup`+WAL 아카이빙(무거움)이 필요.
- **`pg_dump`는 MVCC 트랜잭션 스냅샷**으로 실행 중 DB에서도 **단일 시점 일관 사본**을 만든다.
  포터블 파일 하나 → 버킷에. 지금 규모에 가장 단순·견고.
- 블록스토리지/서버 스냅샷(인프라 레벨)은 **보완재**(§A.4)로만. 복원 입도가 거칠고 포터블하지
  않아 주 수단 아님.

## A.3 백업 — pg_dump → Object Storage (일배치)

VM cron 일 1회:

```bash
# custom 포맷(-Fc): 압축 + 선택 복원. 파일 하나로 product+app_logs 전부 포함.
docker compose -f docker-compose.prod.yml --env-file .env.prod \
  exec -T postgres pg_dump -U postgres -Fc scatchlm > /tmp/scatchlm-$(date +%F).dump

# NCP Object Storage 업로드(S3 호환). 자격증명은 .env.prod의 OBJECT_STORAGE_* 재사용.
aws --endpoint-url https://kr.object.ncloudstorage.com \
  s3 cp /tmp/scatchlm-$(date +%F).dump \
  s3://scatchlm-prod/backups/db/scatchlm-$(date +%F).dump
rm -f /tmp/scatchlm-$(date +%F).dump   # VM 디스크에 덤프 누적 금지(디스크 경쟁 회피)
```

- 한 덤프가 **product 데이터 + `app_logs`를 동시에** 커버(같은 DB).
- 스트림 업로드(`pg_dump | aws s3 cp -`) 또는 임시파일 즉시 삭제 — 9.8G 디스크에 누적 금지.
- 구현체는 cron 스크립트 또는 boto3 택1. 엔드포인트·자격증명은 `storage.py`/`.env.prod`
  (`OBJECT_STORAGE_*`) 재사용 — **신규 인프라 0**.
- **보존:** Object Storage **lifecycle 규칙**으로 자동 만료 — 일별 14일 + 주간 8개 롤링(초안).
  VM이 아니라 버킷이 보존 관리.

## A.4 복구 (restore)

핵심: **빈 Postgres에 덤프를 부어 되살린다.**

**동일 VM에서 되돌리기:**
```bash
aws --endpoint-url https://kr.object.ncloudstorage.com \
  s3 cp s3://scatchlm-prod/backups/db/scatchlm-<DATE>.dump .
docker compose -f docker-compose.prod.yml --env-file .env.prod \
  exec -T postgres pg_restore -U postgres -d scatchlm --clean --if-exists \
  < scatchlm-<DATE>.dump
```

**VM 통째 유실 시 (진짜 시나리오):**
1. 새 VM 프로비저닝 → **`.env.prod` 배치**(§A.6) → docker compose 스택 기동(빈 `pgdata`).
2. 버킷에서 최신 덤프 다운로드.
3. (필요 시) DB·확장 선행 생성 후 `pg_restore`.
4. app 재연결 → 복구 완료.

> **구조 요약:** VM은 일회용, **진짜 자산은 버킷의 덤프.** VM이 죽어도 덤프가 있으면 새 박스에서
> 부활한다 — 이것이 "오프박스 사본"의 본질.

### A.4.1 (선택) VM 스냅샷 — 보완재

NCP 서버/블록스토리지 스냅샷 주기 설정. 앱 변경 0의 통짜 안전망. pg_dump보다 시점 일관성·
복원 입도는 거칠지만 보완재로 저렴. **§A.3을 대체하지 않고 보강.**

## A.5 복구 드릴 — 생략 불가, 백업과 한 세트

**복원해본 적 없는 백업은 백업이 아니다.** 매니지드로 가도 이 책임은 남는다.

- 덤프 1개를 임시 컨테이너/로컬에 §A.4로 복원해 **스키마·주요 테이블 row 수·복원 소요시간**을
  검증하고 절차를 본 문서/`DEPLOY.md`에 문서화.
- **pgvector 함정 주의**: 복원 대상 DB에 `CREATE EXTENSION vector`가 선행돼야 할 수 있다(덤프
  포함 여부·권한 확인). 안 돌려보면 **사고 당일에** 발견한다.
- 분기 1회 등 주기적 재검증 권장.

## A.6 인접 이슈 — `.env.prod` 시크릿 (백업 아님, 복구 전제)

`.env.prod`는 VM 로컬에만 있고 git 제외라, **VM 유실 시 함께 사라지면 §A.4 복구가 막힌다**.
단 이건 "데이터 백업"이 아니라 **시크릿 보관** 문제:

- 시크릿 매니저(1Password 등)에 `.env.prod` 사본 보관 — DB 덤프 버킷과 **분리**(권한 경계).
- 복구 드릴(§A.5) 문서에 **"새 VM에 `.env.prod` 확보"를 전제 단계**로 명시.

---

# Part B — 활동 로그 영속화 (app_logs)

## B.1 문제 — 로그가 컨테이너 인스턴스에 묶여 있다

운영 로그는 Docker 기본 `json-file` 드라이버로 호스트에 쌓이지만 **컨테이너 인스턴스 ID에
종속**된다. 배포(`pull app && up -d`)가 컨테이너를 재생성하면 이전 json-log는 `docker rm`과
함께 사라진다. 2026-06-04 `/check-prod-logs users 24h`에서 `--since 24h`인데 16.5h만 조회됨
(app `Created`=로그 시작점). 즉 **`backend/**` 배포마다 운영 로그 리셋.**

| 항목 | 값 | 함의 |
|---|---|---|
| LogDriver | `json-file`, `LogOpts: map[]` | 로테이션 설정 없음 |
| `/etc/docker/daemon.json` | 없음 | 전역 로테이션도 없음 |
| app json-log | 3.2M / ~26h (일 ~3MB) | 디스크 폭주는 단기 위험 아님 |

### B.1.1 왜 "인스턴스 로컬 영속화"가 아닌 "Postgres 적재"인가

json-file 로테이션·마운트 볼륨 tee는 폐기 — **배포 유실은 막아도 VM 유실엔 그대로 죽고**,
운영이 여전히 `ssh+grep`에 묶인다. 대신 **app을 이미 통과하는 ingest 경로 그대로 Postgres에
적재**한다: 배포에 안 죽고, `users` 분석이 SQL 집계(이메일 JOIN 한 쿼리)가 되며, 추가 인프라
0. VM-유실 durability는 **Part A의 DB 덤프가 함께 커버**한다(같은 DB라 덤프 하나가 `app_logs`
포함) — Part B는 별도 백업 트랙이 필요 없다.

### B.1.2 현재 ingest 경로 (재사용 대상)

FE 로그는 `LogService`가 2초 주기로 `POST /api/dev/log/batch`에 보내고, `devlog.py._emit`이
`[FE ts][trace][sess][u][rid][tag] message | data` 포맷으로 `logging.getLogger("fe")`에 찍는다
(`backend/app/routers/devlog.py`). **이 함수가 모든 FE 텔레메트리의 단일 통로** — 여기에 DB
적재를 붙이면 호출부 수정 없이 전체 적재(인터셉터 일괄, cf. `ux-log-telemetry-spec.md` §1.2).
`LogContext`: `user_id/session_id/trace_id/app_version/build/os_version/device_model/locale`.
`LogEntry`: `level/tag/message/data/ts/request_id/trace_id`.

## B.2 Goal / Non-Goal

**Goal:** (1) FE 텔레메트리를 `app_logs` 테이블에 영속 적재(배포 생존). (2) `/check-prod-logs
users`를 SQL 집계+`users` JOIN으로 전환할 기반. (3) 적재 **best-effort**(DB 실패가 엔드포인트를
안 깸). (4) 보존 정책으로 무한 증식 방지.

**Non-Goal:**

| 항목 | 이유 |
|---|---|
| 에러 트리아지(Sentry) 재활성화 | 별건. 환경 이슈는 메모리 `project_sentry_spm_deadlock` |
| 백엔드 자체 로그(`[access]`/RAG/traceback) 적재 | `_emit` 미경유. §B.5 한계, 필요 시 `logging.Handler` 확장(후속) |
| json-file 로테이션 | B.1.1에서 폐기. 디스크 가드로만 선택 보강(Track C) |
| 로그 라인 Object Storage 콜드 아카이브 | durability는 Part A DB 백업이 커버. 원본 라인 아카이브는 범위 밖 |
| FE 로그에 PII 적재 | 의도된 가명화 — `user_id`만, 식별은 `users` JOIN |
| `/check-prod-logs` 스킬 재작성 | 범위 제외 아님 — **순서상 필수 후속**(Track B·체크리스트) |

## B.3 Data Model — `app_logs` (`backend/app/models/app_log.py`)

`usage.py`(LLMUsage) 패턴. `Base`는 `app.models.user`에서 import.

| 컬럼 | 타입 | nullable | index | 비고 |
|---|---|---|---|---|
| `id` | String (uuid) | NO | PK | `uuid4()` |
| `ts` | DateTime | NO | YES | FE `entry.ts`/`timestamp` 파싱, 실패 시 수신 시각 |
| `received_at` | DateTime | NO | — | 백엔드 수신 시각 |
| `level` | String | NO | — | info/warn/error/debug |
| `tag` | String | NO(기본 "") | YES | `[note]`/`[sync]`/`[auth]`/`[ux]` 등 집계 키 |
| `message` | Text | NO | — | |
| `data` | JSONB | YES | — | `entry.data` 원본(쿼리 유리) |
| `user_id` | String | YES | YES | **전체값**(절단 X — JOIN용) |
| `session_id` | String | YES | YES | 전체값 |
| `trace_id` | String | YES | — | entry 우선, 없으면 context |
| `request_id` | String | YES | — | |
| `app_version`/`build`/`os_version`/`device_model`/`locale` | String | YES | — | context |

> **절단 없이 전체 ID 저장:** 로그 포맷은 `[u:...][:8]`로 절단하지만 테이블엔 전체값 →
> `users.id`(uuid)와 equi-join. prefix LIKE 우회 불필요.

**Index:** `ix_app_logs_ts`, `ix_app_logs_user_id`, `ix_app_logs_session_id`, `ix_app_logs_tag`,
(선택) 복합 `(user_id, ts)`.

**Alembic:** 모델 추가 후 `alembic revision --autogenerate -m "add app_logs table"` +
`upgrade head`. **운영 적용은 수동**(CLAUDE.md 배포 정책):
`ssh scatchlm '... exec -T app alembic upgrade head'`.

## B.4 Tracks

### Track A — 적재 (`devlog.py`, 인터셉터 일괄)

`_emit`은 동기, 라우터는 async → **DB 적재는 라우터에서 배치 단위로**.
1. 기존 `_emit`(콘솔 로깅) 유지 — 라이브 `docker logs` 관측 이중화.
2. `entry+context` → `AppLog` row 리스트 매핑 → `session.add_all` + commit(배치 1회).
3. **Best-effort:** 적재 블록 `try/except`, 실패 시 `log.warning`만, `{"received": N}`은 정상 반환.
4. `ts` 파싱 ISO8601 우선, 실패 시 `received_at` 폴백.
5. DB 세션: `core/database` async 세션 의존성 주입(feedback 라우터 패턴).

> **부하:** 클라당 2초 배치 × 동시 사용자. 현재 한 자릿수라 무시 가능. 증가 시 큐+백그라운드
> flush 또는 `data` 선택 적재로 경량화 — 현 범위 밖.

### Track B — `users` 분석을 SQL로 (필수 후속, 스킬 갱신)

적재가 운영 반영되면 `.claude/commands/check-prod-logs.md`의 `users`/`stats` 섹션을 **grep
집계 → SQL 집계로 전환**한다. 안 하면 적재만 하고 분석은 휘발성 json-log에 의존하는 절름발이.
- 로그 fetch+grep 파이프라인을 아래 SQL(`/check-prod-db` 경유)로 교체.
- "prefix→이메일 자동 JOIN" 단계는 SQL `LEFT JOIN users`로 흡수.
- **단, `--since` 윈도우 경고·라이브 tail(`follow`)·키워드 grep은 유지**(json-log 직접 봐야
  하는 용도). → "활동 집계=SQL, 라이브/단발 grep=기존"의 이원화.
- 백엔드 `[access]`는 `app_logs`에 없으므로(§B.5) 당분간 grep 유지.

```sql
-- 최근 24h 고유 사용자 + 이메일 + 로그량 + 세션수
SELECT l.user_id, u.email, count(*) AS log_count,
       count(DISTINCT l.session_id) AS sessions,
       min(l.ts) AS first_seen, max(l.ts) AS last_seen
FROM app_logs l LEFT JOIN users u ON u.id = l.user_id
WHERE l.ts > now() - interval '24 hours'
GROUP BY l.user_id, u.email ORDER BY log_count DESC;

-- 액션 태그 빈도
SELECT tag, count(*) FROM app_logs
WHERE ts > now() - interval '24 hours' AND tag <> ''
GROUP BY tag ORDER BY count DESC LIMIT 40;

-- uxTrack 결과 분포
SELECT data->>'result' AS result, count(*) FROM app_logs
WHERE ts > now() - interval '24 hours' AND tag IN ('ux','uxError')
GROUP BY 1 ORDER BY 2 DESC;

-- 에러
SELECT ts, user_id, tag, message FROM app_logs
WHERE ts > now() - interval '24 hours' AND level = 'error'
ORDER BY ts DESC LIMIT 30;
```

> `LEFT JOIN`이라 로그엔 있으나 `users`에 없는 user_id(가입 실패/삭제)는 `email IS NULL`로
> 드러난다 — grep 시절 "미가입 prefix" 수기 판정 대체.

### Track C — 디스크 가드 (선택)

Postgres 적재가 주 싱크라 json-file은 라이브 tail 용도로만. 컨테이너 장수 시 json-log 폭주
안전망으로 daemon 로테이션만(`/etc/docker/daemon.json` → `systemctl restart docker`):
```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
```
우선순위 낮음(현 일 ~3MB). 필수 아님.

### Track D — 보존(retention)

`DELETE FROM app_logs WHERE ts < now() - interval '90 days';` (90일 초안). 자동화는 후속
(일배치 cron 또는 app 백그라운드 prune, 동시성 가드 필요).

## B.5 한계 / 후속

- **백엔드 자체 로그 미포함**: `[access]`/RAG/traceback은 `_emit` 미경유 → `app_logs`에 없음.
  필요 시 `logging.Handler` 서브클래스로 uvicorn 로거 → `app_logs`(별도 트랙).
- **대용량화**: 적재를 큐+백그라운드 flush로, 분석을 머티리얼라이즈드 뷰로 — 다음 단계.

---

## 통합 작업 체크리스트

> **구현 현황 (2026-06-04):** 코드/스크립트/문서는 완료. **남은 건 VM·NCP 콘솔·시크릿
> 매니저 수동 작업뿐**(아래 ⏳ 표시). 코드는 main 푸시 → CI 자동 배포되지만 alembic은 수동 적용.

**Part A — 백업 (실질 최우선)**
- [x] **§A.3 pg_dump → Object Storage 스트림 업로드** — `scripts/backup_db.sh` + `scripts/upload_stream.py`(app 이미지 동봉). 임시파일 없음.
- [ ] ⏳ **§A.3 cron 등록** — VM `/opt/scatchlm/scripts/`에 scp + `crontab -e`(DEPLOY.md 절차). *VM 수동*
- [ ] ⏳ **§A.5 복구 드릴 1회 수행** — `scripts/restore_db.sh` 작성됨. 절차는 DEPLOY.md. 실제 1회 복원 검증은 *수동*
- [ ] ⏳ §A.3 Object Storage lifecycle 보존(일14/주8) — **NCP 콘솔** `backups/db/` prefix 만료 규칙
- [ ] ⏳ §A.6 `.env.prod` 시크릿 매니저 보관 — **외부 SaaS(1Password 등)**. DEPLOY.md에 복구 전제 문서화 완료
- [ ] ⏳ §A.4.1 (선택) NCP VM 스냅샷 주기 — **NCP 콘솔**
- [x] 백업 성공/실패 처리 — `backup_db.sh`가 실패 시 비-0 exit + `BACKUP_ALERT_CMD` 훅. cron 로그(`/var/log/scatchlm-backup.log`)

**Part B — 로그 적재**
- [x] `backend/app/models/app_log.py` — `AppLog` 모델 (§B.3)
- [x] alembic `env.py` import 등록 (`__init__.py`는 빈 파일 — env.py가 실 import 지점)
- [x] 마이그레이션 `d4e5f6a7b8c9_add_app_logs_table.py` (autogenerate 등가, 수기 작성)
- [x] `devlog.py` — 배치 핸들러 best-effort DB 적재 + ts 폴백 (§B.4 Track A)
- [x] 회귀 테스트 4종: 적재 성공/DB 실패 시 200/ts 폴백/빈 배치 (작성만, 실행 CI)
- [ ] ⏳ **운영 마이그레이션 수동 적용** — `ssh scatchlm '... exec -T app alembic upgrade head'`. *VM 수동*
- [x] Track D retention — `scripts/prune_app_logs.sh`(90일). cron 등록은 위 ⏳에 포함
- [ ] (선택) Track C json-file 로테이션 — 우선순위 낮음(일 ~3MB), 미구현
- [x] **(필수 후속) `check-prod-logs.md` `users`/`stats` SQL 집계 전환** (§B.4 Track B)

---

## 관련 문서

- `ux-log-telemetry-spec.md` — FE 텔레메트리 포맷/인터셉터 일괄 원칙(Part B가 그 ingest 경로 재사용).
- `.claude/commands/check-prod-db.md` — `backup` 옵션(수동 pg_dump)이 §A.3 자동화의 출발점.
- `.claude/commands/check-prod-logs.md` — `users` 분석. Part B Track B에서 SQL로 전환 대상.
- `backend/DEPLOY.md` — 복구 절차(§A.4) 문서화 위치 후보.
