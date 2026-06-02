# GitHub Repo Viewer Spec: PDF 교재 자리에 코드 repo 띄우기

> **Status:** Draft
> **Date:** 2026-06-01
> **Author:** (auto-generated)

---

## 1. Background

### 1.1 아이디어

ScatchLM은 PDF 교재를 좌(상) 40%에 띄우고 우(하) 60% PencilKit 캔버스에서 필기·AI 피드백을 받는 학습 앱이다. 이 자리에 **GitHub repo를 띄워, 코드를 읽고 필기하며 멘탈 모델을 잡는** 용도로 확장한다.

목표 사용 시나리오 (사용자 확정): **"이 repo 전체에서 뭐가 어디 있는지 / 어떻게 엮이는지 탐색"** 이 1순위. "지금 보는 이 파일 이해" 는 부차적.

**제품의 정체 (사용자 확정):** 뷰어 위 PencilKit 필기는 보류(필요성 낮음, §1.4). 따라서 **뷰어는 코드를 읽는 표면일 뿐이고, 이 기능의 본체는 "청킹 + 호핑으로 repo를 탐색하는 검색 엔진"**이다. 명세의 무게중심은 §3(청킹)·§7(검색·호핑 전략)에 있다.

### 1.2 PDF 파이프라인과의 구조적 대응

기존 교재 파이프라인은 `Source → 구조 → 청킹 → 임베딩 → RAG → 가이드` 형태다. Repo도 같은 골격에 올리되, 각 단계의 의미가 달라진다.

| PDF 교재 | GitHub Repo | 재사용 |
|---|---|---|
| `TextbookSource` (파일+해시+페이지수) | `RepoSource` (owner/repo+commit SHA+파일수) | 형제 모델 신규 |
| 페이지 (1..N, 선형) | 파일 트리 (계층, 비선형) | **UI 전면 교체** |
| TOC / LLM 챕터 감지 | 디렉터리 구조 (이미 트리) | 감지 불필요 |
| 단락 청킹 (2000자 정규식) | **심볼 단위 휴리스틱 청킹** | **교체** |
| Voyage 임베딩 | Voyage 임베딩 | 그대로 |
| 페이지/챕터 가이드 | 파일/모듈 멘탈모델 가이드 | 프롬프트 교체 |
| RAG 채팅 (현재 챕터 1회 주입) | **코드 그래프 beam search**(MVP) → agentic loop(P2) | **재설계** |

### 1.3 핵심 설계 판단 — "충분한 컨텍스트 단위"

PDF 채팅이 실제로 일을 하는 방식은 `수동 범위 > 현재 페이지 포함 챕터 > RAG 자동 검색` 우선순위(`feedback.py:76-120`)다. 즉 **임베딩 RAG는 거의 안 쓰이는 폴백**이고, 진짜로 동작하는 건 "현재 페이지 → 그 챕터를 통째로 전달"이다.

**이게 충분했던 이유 (코드엔 없는 속성):**
1. **자기완결성** — 교과서 챕터는 그것만 읽어도 이해된다. 코드 파일은 import한 외부 심볼 정의가 있어야 이해된다.
2. **선형적 locality** — 독자의 "현재 페이지"가 강한 의도 신호다. 코드 공부는 call graph를 따라 점프하므로 "현재 파일"은 약한 신호다.

**결론: 코드엔 "챕터"처럼 깔끔한 정적 슬라이스 경계가 없다.** 두 가지 질문 유형으로 분리한다.

| 질문 유형 | 메커니즘 | 우선순위 |
|---|---|---|
| "이 repo에서 X 어디 있나 / Y는 어떻게 했나" | 심볼 단위 **의미 검색** | **1순위** |
| "A→B→C가 어떻게 엮이나 (아키텍처 배선)" | **그래프 traversal** | 1순위(동반) |
| "지금 보는 이 파일 이해" | 파일 + 직접 의존 (구조적 컨텍스트) | 부차 |

**다중 hop의 함정 (명시적 기록):** "2-hop 이상 필요"라는 직관은 옳지만, 이를 *N-hop transitive closure를 컨텍스트에 욱여넣기*로 풀면 "전체 컨텍스트는 곤란하다"는 원래 문제를 그래프 경로로 재현한다 (1-hop 5파일 → 2-hop 25 → 3-hop 100+). **해법은 더 큰 덤프가 아니라, 모델이 개발자처럼 도구로 탐색하게 하는 것이다.** 따라간 경로만 비용을 치르므로 hop 깊이는 무제한이지만 비용은 유한하다 (§7).

### 1.4 Out of Scope

| 항목 | 이유 |
|---|---|
| Private repo | 1차는 public-only (토큰 불필요, tarball 공개 API). 사용자별 GitHub OAuth/PAT는 별도 Phase |
| 정밀 call-graph (find-references) | tree-sitter + 심볼 해석 필요. MVP는 import 엣지(정규식)까지만. Phase 2 |
| tree-sitter AST 청킹 | MVP는 휴리스틱(함수 경계 + 줄 수 상한). 품질 업그레이드는 Phase 2 |
| 실시간 repo sync (push/webhook) | commit SHA로 핀 고정. 재인덱싱은 수동 트리거 |
| repo 내 코드 실행 / 빌드 | 읽기·이해 전용 |
| 대용량 repo (수만 파일) 전체 인덱싱 | 파일 수·바이트 상한으로 컷. 초과분은 §3.3대로 사용자에게 고지(silent truncation 금지) |
| PDF·repo 혼합 노트 | 노트 1개당 source 1개 |
| **뷰어 위 PencilKit 필기 통합** | **보류 (사용자 확정).** 필요성 낮음 + 하이라이팅 위 캔버스 좌표 동기화 비용 큼. 뷰어는 읽기 전용 표면으로만. 제품 본체는 청킹+호핑 엔진 |

---

## 2. 데이터 모델

`TextbookSource`는 손대지 않고 형제 테이블을 둔다 (기존 PDF 코드 변경 면적 최소화). `DocumentChunk`만 다형성으로 확장해 임베딩 검색 인프라를 공유한다.

### 2.1 Backend (PostgreSQL / Alembic 신규 마이그레이션)

```
RepoSource:
  id, user_id
  owner, repo, ref(branch/tag)          # 사용자 입력
  commit_sha                            # import 시점 핀 — 불변. 재인덱싱 기준
  default_branch
  file_count, indexed_file_count, total_bytes
  status: pending | indexing | ready | failed | truncated
  truncation_note (nullable)            # 상한 초과 시 무엇이 빠졌는지
  indexed_at, created_at

RepoFile:                               # PDF의 "페이지" 대응
  id, repo_source_id
  path                                  # repo 루트 기준 상대경로
  language                              # 확장자 → 언어 매핑
  size_bytes, blob_sha
  is_binary, is_indexed
  # 본문은 저장하지 않고 필요 시 스토리지/타르볼에서 읽음 (§3)

DocumentChunk:                          # 기존 테이블 재사용 + 다형성 컬럼 추가
  + source_type: pdf | repo             # 기존 행은 'pdf' 백필
  + repo_file_id (nullable, FK)
  + symbol_name (nullable)              # 함수/클래스명
  + start_line, end_line (nullable)
  (기존: text, embedding(512), textbook_id 등)

ImportEdge:                             # MVP 그래프 — import 관계만
  id, repo_source_id
  from_file_id (FK RepoFile)
  to_path                               # 해석된 상대경로 (해석 실패 시 raw 보존)
  to_file_id (nullable FK)              # 내부 해석 성공 시
  raw_import                            # 원문 (디버깅·미해석 추적)
  is_external                           # 외부 패키지면 true
```

> `Chapter` 테이블은 repo에 쓰지 않는다 — 디렉터리 트리가 곧 구조다.

### 2.2 iOS (GRDB 신규 마이그레이션 `vN_repo_source`)

- `Note` 모델 일반화: `textbookId` → `sourceId` + `sourceType(pdf|repo)`. 기존 `textbookId` 컬럼은 호환 유지하되 신규 코드는 `sourceId` 경유.
- 신규 로컬 캐시: `RepoFileCache(repoSourceId, path, content, fetchedAt)` — 뷰어가 연 파일 본문 캐싱 (페이지 PDF 캐시와 동일 패턴).
- `lastPage`/`currentPageIndex` 대응: `lastOpenedPath`(마지막 연 파일).

---

## 3. 인제스천 (PDF upload 대응)

`POST /api/repo/import`

### 3.1 흐름

```
POST /api/repo/import { url 또는 owner/repo, ref? }
  ↓
1. ref 해석 → commit_sha 핀 (GitHub API: GET /repos/{o}/{r}/commits/{ref})
2. tarball 취득 (GET /repos/{o}/{r}/tarball/{sha}) — full clone 대비 경량, .git 불필요
3. RepoSource(status=pending) 생성, 즉시 응답 (BackgroundTasks)
   ↓ 백그라운드
4. 파일 필터링 (§3.2)
5. RepoFile 레코드 생성
6. import 파싱 → ImportEdge (언어별 정규식, §3.4)
7. 심볼 단위 휴리스틱 청킹 (§3.3) → Voyage 임베딩 → DocumentChunk(source_type=repo)
8. status=ready (또는 상한 초과 시 truncated + truncation_note)
```

기존 `index_textbook`(`indexing_service.py:12-59`) 흐름을 그대로 차용하되, 청킹 함수만 코드용으로 분기.

### 3.2 필터링

제외: 바이너리, `.git`, 벤더/빌드 디렉터리(`node_modules`, `dist`, `build`, `vendor`, `.next`, `target` 등), lock 파일, 미디어/폰트. 파일당 상한(예 256KB), repo당 파일 수·총 바이트 상한. **상한 초과 시 `truncation_note`에 무엇이 빠졌는지 기록하고 클라이언트에 노출** (silent truncation 금지).

### 3.3 청킹 (코어 — MVP = 휴리스틱)

청킹 품질이 검색·호핑 품질을 직접 결정한다. MVP는 외부 파서 없이 휴리스틱으로 가되, 아래 두 정제가 품질을 가른다.

**경계:**
- 함수/클래스 시작 패턴(언어별: `def `, `func `, `class `, `function `, `fn `, JS/TS export 등) + 빈 줄 경계로 분할.
- 청크당 줄 수 상한(초기값 80줄, §1.3대로 관측 후 튜닝) — 초과 시 강제 분할, `start_line/end_line` 기록.
- 작은 파일은 통째로 1청크.

**정제 1 — embed는 enriched, 저장은 raw (검색 품질의 핵심):**
- 임베딩 입력 = `path` + `symbol_name` + signature + (가능하면) docstring/leading comment 를 prefix로 붙인 텍스트. → "어디 있나" 검색 recall 상승.
- 컨텍스트로 LLM에 주입하는 본문 = raw 코드 (군더더기 없음).
- 즉 `embedding`은 enriched 텍스트로 만들고, `DocumentChunk.text`에는 raw를 저장.

**정제 2 — 각 청크를 hop 노드로 (§7 호핑 전제):**
- 청크 메타에 그 파일의 import 목록(→ `ImportEdge`)과 감싸는 클래스/파일 헤더를 실어, beam 확장이 청크에서 바로 엣지를 꺼낼 수 있게 한다.
- 메서드 청크는 enclosing 타입/시그니처를 헤더로 포함해 self 타입 맥락 보존.

- **Phase 2: tree-sitter로 정확한 심볼 경계 + `symbol_name` 정밀화 + 정밀 call-graph.**

### 3.4 import 엣지 (MVP)

언어별 정규식으로 import/require/include 문 추출 → 상대경로 해석 시도. 내부 해석 성공이면 `to_file_id` 연결, 외부 패키지면 `is_external=true`, 실패면 `raw_import`만 보존. 정밀 해석(별칭, re-export, dynamic import)은 Phase 2.

---

## 4. iOS 뷰어 (읽기 전용 표면 — 우선순위 낮음)

캔버스 필기 통합이 보류되면서 뷰어는 "코드를 읽고 출처(`[path:line]`)로 점프하는 표면"으로 축소된다. 본체(§3·§7)가 우선이며, 뷰어는 검색 결과를 보여줄 최소 수준이면 된다.

- **파일 트리 네비게이터**: 접이식 디렉터리, 경로 검색, 현재 파일 하이라이트.
- **코드 뷰어**: 문법 하이라이팅. 후보 — `Highlightr`(highlight.js 래핑) 또는 `WKWebView` + Prism. 줄 번호 표시(출처 점프 연동). 캔버스를 안 겹치므로 좌표 동기화 문제 없음 → 렌더러 선택 자유로움.
- **README/마크다운**: 기존 `MarkdownUI` 의존성 재사용.
- **채팅 출처 점프**: 응답의 `[path:line]` 탭 → 해당 파일·줄로 스크롤. (이게 뷰어의 주 역할.)
- (보류) NoteView 분할·PencilKit 캔버스 통합 — §1.4.

---

## 5. AI 가이드 (멘탈 모델 보조)

`guide_service` 대응, 프롬프트만 코드용.

- **파일 가이드** (`GET /api/repo/{id}/file-guide?path=`): "이 파일의 역할 / 핵심 심볼 / 어디서 호출되나(import 엣지 기반) / 주의점". Lazy 캐싱.
- **디렉터리/모듈 가이드** (`GET /api/repo/{id}/module-guide?path=`): "이 모듈이 시스템에서 하는 일 / 진입점". Lazy 캐싱.
- (Phase 2) repo 전체 아키텍처 개요 — 비용 큼, 후속.

---

## 6. API 엔드포인트 요약

| 엔드포인트 | 메서드 | 기능 |
|---|---|---|
| `/api/repo/import` | POST | repo import 시작 (commit 핀, 백그라운드 인덱싱) |
| `/api/repo/sources` | GET | 내 repo 목록 |
| `/api/repo/{id}/status` | GET | 인덱싱 진행/완료/truncation_note |
| `/api/repo/{id}/tree` | GET | 파일 트리 (계층 JSON) |
| `/api/repo/{id}/file?path=` | GET | 파일 본문 서빙 |
| `/api/repo/{id}/file-guide?path=` | GET | 파일 가이드 (Lazy) |
| `/api/repo/{id}/module-guide?path=` | GET | 모듈 가이드 (Lazy) |
| `/api/repo/chat` | POST | **검색·호핑 채팅 (§7): MVP beam search → P2 agentic** |

---

## 7. 검색·호핑 전략 (제품 본체)

**문제 재확인 (§1.3):** 코드의 관련 컨텍스트는 파일들로 흩어져 있어 단발 RAG(top-k 1회)로는 multi-hop("X 찾고 → X가 의존하는 것 → ...")을 못 한다. 반면 N-hop transitive closure를 컨텍스트에 욱여넣으면 "전체 컨텍스트 곤란" 문제를 그래프 경로로 재현한다(1-hop 5 → 2-hop 25 → 3-hop 100+). **둘 다 안 되는 사이의 해법이 필요하다.**

### 7.1 MVP = 코드 그래프 위 beam search (결정론적, 저렴, 디버깅 가능)

각 hop마다 top-W로 prune → 전체 closure를 들고 있지 않음. 너비는 고정(W), 깊이(D)만 키움 → **multi-hop인데 비용 유한.** LLM은 루프 안에 없고 마지막 답변에만 등장.

```
Stage 0 (seed):   semantic_search(query) → 상위 W개 seed 청크 (beam width W)
Stage i (expand): 각 beam 청크의 이웃 수집
                    - 나가는 import 엣지(ImportEdge: from=현재 파일)
                    - 들어오는 import 엣지(to=현재 파일) — "누가 이걸 쓰나"
                    - 같은 파일 내 형제 심볼
                  → 이웃 청크를 query에 대해 재점수(임베딩 유사도)
                  → 전체에서 상위 W개만 유지 (prune), 방문 set으로 사이클 차단
반복:             D hop 또는 점수 plateau(신규 이웃이 임계 미만)까지
최종:             살아남은 beam 집합 → LLM 프롬프트 주입 → 답변
```

- **파라미터**: W(beam width)·D(max depth)는 §1.3대로 미리 확정하지 말고 관측 후 튜닝. 각 hop의 beam을 `appLog`로 적재해 실제 깊이 분포 수집.
- **장점**: 결정론적 → 같은 질문 같은 결과, 재현·디버깅 쉬움. LLM-in-loop 비용 없음.
- **redundant 내비게이션 (엣지 누락 보정):** 정규식 import는 별칭·re-export·dynamic을 놓친다. seed 단계의 semantic_search + (필요 시) grep이 import 엣지가 끊긴 노드도 점수로 끌어오므로, 한 경로가 막혀도 다른 경로가 메운다.

### 7.2 Phase 2 = agentic loop (추론 기반 trace)

beam은 *relevance*로 확장한다 → "X 어디 있나/누가 쓰나"엔 강하지만, "라우트→서비스→DB로 요청이 어떻게 흐르나" 같은 **호출 순서 추론**은 relevance가 아니라 실제 엣지 시퀀스를 따라가야 해서 약하다.

이때 도구를 가진 Anthropic tool-use 루프로 모델이 직접 탐색:

| 도구 | 동작 |
|---|---|
| `semantic_search(query, k)` | 심볼 청크 임베딩 검색 (`retrieval_service` 재사용, source_type=repo) |
| `read_symbol(path, name?)` | 파일/심볼 본문 (`RepoFile` + 줄 범위) |
| `list_imports(path)` | 파일의 import 엣지 (in/out, `ImportEdge`) |
| `find_references(symbol)` | 심볼 호출처 (정밀 call-graph — tree-sitter 선행 필요) |
| `grep(pattern)` | 텍스트 정확 검색 |

- 모델이 어느 엣지를 따라갈지 결정 → 따라간 경로만 비용 → 깊이 무제한, 비용은 도구호출·토큰 상한으로 가드.
- 트레이드오프: beam 대비 레이턴시·토큰↑, 비결정론적(디버깅 어려움). 그래서 1순위("어디/배선")는 beam으로 처리하고, agentic은 "흐름 추적"이 필요할 때만.

### 7.3 공통

- **출처 표기**: PDF의 `[p.33]` 대신 `[path:line]`. 클라이언트는 탭 시 뷰어에서 해당 파일·줄로 점프(§4).
- 모든 응답은 기존 `AIResponse`에 `source_type=repo`, `repo_source_id` 적재 (평가 일관성).
- `/api/repo/chat`은 MVP에서 beam 결과를 단발 주입(상태 없음 → PDF 채팅과 동일한 단순 형태). agentic은 Phase 2에서 tool-loop로 교체.

---

## 8. MVP 컷 & 단계

### Phase 1 (MVP) — 본체: 청킹 + beam 호핑
- public repo only, tarball import + commit 핀
- **청킹**: 휴리스틱 경계 + enriched-embed/raw-store + 청크에 import 메타 (§3.3)
- **그래프**: import 엣지(정규식, in/out) (§3.4)
- **검색·호핑**: 코드 그래프 beam search (§7.1) → 단발 주입 채팅
- 뷰어: 파일 트리 + 하이라이팅 (읽기 전용, 출처 점프) — 최소 수준
- 파일/모듈 가이드 (Lazy)

### Phase 2
- tree-sitter 정밀 청킹 + 정밀 call-graph(`find_references`)
- **agentic loop 채팅** (추론 기반 흐름 추적, §7.2)
- private repo (GitHub OAuth/PAT)
- repo 전체 아키텍처 개요 / 의존성 그래프 시각화
- repo sync (commit 갱신 재인덱싱)
- (보류 해제 시) PencilKit 캔버스 통합

---

## 9. Open Questions

1. **beam 파라미터 W·D**: 미리 확정 말고 관측 후 튜닝(§1.3, §7.1). 각 hop의 beam을 `appLog`로 적재 → 실제 깊이 분포·점수 plateau 지점 수집 후 결정. **가장 먼저 PoC할 것** — 본체이므로.
2. **이웃 재점수 비용**: hop마다 이웃을 임베딩 유사도로 재점수. 이웃 임베딩은 인덱싱 시 이미 저장돼 있으므로 query 임베딩 1회 + 벡터 내적 → 저렴. 단 W·D가 크면 내적 횟수 증가 — pgvector 인덱스 활용 여부 확인.
3. **청킹 줄 수 상한**: §1.3대로 "미리 결정 말고 관측 후 튜닝". 초기값만 두고 검색 품질 로그로 조정.
4. **하이라이팅 렌더러**: 네이티브(`Highlightr`) vs `WKWebView`(Prism). 캔버스 보류로 좌표 동기화 문제는 사라짐 → 우선순위 낮음.
4. **GitHub API rate limit**: 미인증 60req/h. import 1회는 commit 조회 + tarball ≈ 2req라 여유. 그래도 인증 토큰(앱 단위) 둘지 검토.
5. **노트-repo 링크 sync**: cloud-data-sync-spec과 맞물림 — `sourceId`/`sourceType` 일반화가 동기화 모델에 반영돼야 함 ([[project_local_db_user_isolation]] 관련).
