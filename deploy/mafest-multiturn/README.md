# 멀티턴 상태 저장 — 플랫폼 정적 준비 인계

상태: **멀티턴 세션 저장소 배포 선언 완성(로컬 렌더·정적 검사까지) / 이미지 digest 미확정 / 운영 적용·Secret 생성·DB 마이그레이션·장애 시험 미실행.**
앱 기준: API `c48f578`, 웹 `f87c580`(둘 다 게시 이미지 digest 미확정). 앱 계약의 정본은 앱 저장소의 `config.py`, `session/schema.py`, `session/migrate.py` 다.
`drafts/` 는 `.draft`·`.tmpl` 확장자라 어떤 kustomize 렌더에도 들어가지 않는다. 적용되는 선언은 API Deployment(세션 env·Secret 참조),
CNPG Cluster(`mafest_session` managed role), `db/grants/mafest_roles.sql`(CONNECT 한 줄)이다. 작업 기준: `origin/develop@e79e0c5`.
실클러스터·DB·SSH·LLM에는 접속하지 않았다. 아래 "라이브 값"은 모두 사용자 제공 기록이며 이번에 확인하지 않았다.

## 읽는 순서

| 순서 | 파일 | 역할 |
| --- | --- | --- |
| 1 | 이 문서 | 현황 대조, 합의 목록, 배포 순서, 후속 승인 순서 |
| 2 | `drafts/api-db-credential.patch.yaml.draft` | 비밀번호 없는 PGURL + PGPASSWORD 분리 제안 (비활성) |
| 3 | `scripts/mafest_sync_db_secret.py` | namespace 간 비밀번호 전달 도구. 기본은 계획 출력, 값은 디코드·출력하지 않음 |
| 4 | `scripts/test_mafest_credentials.py` | 위 도구와 libpq의 PGPASSWORD 동작을 합성 값으로 시험 |
| 5 | `drafts/session-role-grants.sql.tmpl` | **대체됨.** 세션 role 권한은 마이그레이션 CLI 의 `--app-role` 이 준다. 참고로만 남김 |
| 5b | `db/grants/mafest_session_precheck.sql`, `db/grants/mafest_session_check.sql` | 세션 스키마 사전 점검(소유권을 바꾸지 않음)과 마이그레이션 후 유효 권한 검사(둘 다 읽기 전용) |
| 6 | `drafts/migration-job.yaml.draft`, `drafts/network-policy.yaml.draft` | 마이그레이션 Job(적재 Job 패턴·기존 loader 정책 재사용, digest만 미확정)과 정리 CronJob 몫의 NetworkPolicy 초안 |
| 7 | `drafts/session-cleanup-cronjob.yaml.draft` | 정리 CronJob (`suspend: true`, 삭제 SQL 없음) |
| 8 | `scripts/mafest_deploy_order.py` | 마이그레이션 → 확인 → API 선택 Sync 절차와 검사기 (실행 모드 없음) |
| 9 | `scripts/check_mafest_multiturn_prep.py` | 위 초안들의 정적 검사기 |
| 10 | `scripts/fault/mafest_fault.py`, `scripts/fault/llm-call-basis.json`, `scripts/fault/e0-inputs.example.json` | 장애 시험 도구 (E0만 구현), 경로별 LLM 호출 상한 증명, 입력 예시 |
| 11 | `scripts/fault/proof/` | 증명을 다시 확인하는 관찰 플러그인(`llm_spy.py`)과 재현 절차 |

## 1. 현황 대조 (선언 / 제공 기록 / 미검증 라이브)

| 항목 | Git 선언(develop) | 제공 기록(2026-10-14) | 상태 |
| --- | --- | --- | --- |
| API 복제본·배치 | replicas 2, maxSurge 1, maxUnavailable 0, 홈 워커 2대 한정 | 같음 | 선언만 확인. 실제 분산은 `--check` 대상 |
| PDB | `api-pdb.yaml` minAvailable 1 | — | 이미 있음 |
| 종료 예산 | LLM 60 < 요청 90 < graceful 100, preStop 10, 유예 120 | 같음 | 검사기가 선언을 읽어 확인. 변경 없음 |
| readiness | `MAFEST_READINESS_MODE=process`, 의존성 점검 15초 | 같음 | 변경 없음 |
| DB 접속 | `PGURL` 을 `secretKeyRef`(mafest-app/mafest-api-db)로 주입 | mafest-db-rw 단일, sslmode=require, connect_timeout=2 | Secret 내용은 Git 밖이라 확인 불가. 이름·키·소유만 기록 |
| 앱 소스의 연결 방식 | `infra/db_pool.py` 가 DSN을 `parse_dsn → make_dsn` 후 psycopg2 풀로 연결. 주석에는 과거 다중 호스트(-ro,-rw) 권장이 남아 있음 | rw 단일 | **주석이 현재 운영(rw 단일)과 다르다.** 앱 쪽 정리 필요(인계) |
| CNPG | instances 2, owner `mafest_owner`, managed role `mafest_runtime`, max_connections 64 | 현재 Primary db-2 / Replica db-1 | 역할은 변하므로 시험 직전 읽기로 확정 |
| runtime 권한 | `mafest_roles.sql` 이 SELECT만 부여 | — | 유지. 쓰기는 별도 role 제안 |
| DB ingress | `mafest-allow-db-ingress` 가 라벨 mafest-api·mafest-loader 만 5432 허용 | — | 넓히지 않고 새 라벨 전용 정책 초안 추가 |
| Argo | mafest-app·mafest-db 모두 syncPolicy 없음(수동 Sync) | — | 선택 Sync 전제로 절차 설계 |
| 백업 파일 | — | CP의 `mafest-api-db.backup.yaml`(비밀번호 포함, 600) | 열거나 지우지 않음 |

과거 "Replica 우선 연결에서 Primary 장애 중 실패 0건·최대 74ms" 와 "측정 전 24시간 트래픽 0건" 은 현재 rw 단일 구조의 결과나 새 시험의 격리 증거로 쓰지 않는다.

## 2. DB 접속 정본과 비밀 전달

- 드라이버는 psycopg2(libpq). 앱은 `parse_dsn → make_dsn` 으로 DSN을 가공한 뒤 연결한다(`mafest/src/mafest/infra/db_pool.py`).
- **로컬 합성 시험 결과**: 비밀번호 없는 DSN + `PGPASSWORD`(URL 예약문자·공백·따옴표 포함)를 가짜 서버가 원문 그대로 받았고, 인증 실패 예외 문구와 DSN 문자열에 비밀번호가 없었다(psycopg2 2.9.12 / libpq 17). 이는 **로컬 psycopg2 기준**이다. 운영 이미지(psycopg2-binary 2.9.13)와 앱의 풀 초기화 경로에서의 동작은 이미지로 별도 확인해야 한다(미검증).
- 환경변수 전달이 완전히 안전하다는 뜻이 아니다. 같은 Pod 안에서 `/proc/<pid>/environ` 을 읽을 수 있는 주체에게는 보인다. 대안(passfile 볼륨)은 앱 변경 없이 가능하지만 이번에 시험하지 않았다.
- `$(PGPASSWORD)` 를 URL에 치환하는 방식은 쓰지 않는다.
- 제안 패치는 비활성이다. DB 이름·사용자는 Git 선언으로 확인되지 않아 자리표시로 남겼다.
- 전달 도구 `mafest_sync_db_secret.py`: 원본 `mafest-data/mafest-db-runtime` 의 `password` → 대상 `mafest-app/mafest-api-db` 의 `PGPASSWORD`(키 추가만, 기존 `PGURL` 유지). 허용 조합이 코드에 고정돼 있고 `--apply --confirm mafest-api-db --expect-context <승인한 context>` 가 있어야 실행한다(모든 kubectl 호출에 `--context`가 붙는다). 이번에는 가짜 kubectl로만 시험했다.
- 운영 API ServiceAccount에는 Secret 전달 권한을 주지 않는다. 회전·복구: 비밀번호가 바뀌면 원본(CNPG managed role Secret) 갱신 → 도구 재실행 → API 롤링 재시작이 필요하다(재시작 시점 승인 필요).
- 새 오퍼레이터(Sealed Secrets, External Secrets)는 설치하지 않고 후속 과제로만 둔다.

## 3. 권한과 연결 예산

- 검색 `mafest_runtime` 은 읽기 전용을 유지한다. 세션 저장소는 **별도 role `mafest_session`**(CNPG managed role, 로그인만·특권 없음)과 **별도 Secret**을 쓴다.
  - 비밀번호 Secret: `mafest-db-session`(mafest-data, basic-auth). API가 읽는 Secret: `mafest-api-session`(mafest-app, 키 `PGURL_SESSION`·`MAFEST_SESSION_KEY`). 둘 다 사람이 만들며 Git에 값이 없다.
  - 두 API Pod가 같은 `mafest-api-session` 을 참조하므로 같은 서버 키를 쓴다. 로컬 시험에서 만든 세션 DSN·서버 키는 운영에 복사하지 않고 운영용 새 난수(32바이트 이상)로 만든다.
- **DDL(마이그레이션) 계정은 상품 owner(`mafest_owner`, Secret `mafest-migrator`)가 아니라 세션 전용 `mafest_session_migrator`** 다(CNPG managed role, 특권 없음, Secret `mafest-db-session-migrator` / Job 전용 DSN Secret `mafest-session-migrate-db`).
  - 이유: `db/grants/mafest_roles.sql` 의 `ALTER DEFAULT PRIVILEGES FOR ROLE mafest_owner GRANT SELECT ON TABLES / USAGE ON SCHEMAS TO mafest_runtime` 은 owner 가 **어느 스키마에 만들든** 적용된다. owner 로 세션 테이블을 만들면 실행 키·질문이 든 테이블을 검색 계정이 읽게 된다.
    이 전역 기본 권한은 `IN SCHEMA … REVOKE` 로 일부만 제외할 수 없으므로(PostgreSQL 기본 권한 규칙), 상품 owner 의 기본 권한은 건드리지 않고 **owner 를 쓰지 않는 방식**으로 막는다.
  - `mafest_session_migrator` 는 DB `CONNECT, CREATE`(스키마 생성)만 받고 이 역할을 대상으로 한 기본 권한은 없다. 새 스키마·테이블은 이 역할이 소유하며 검색 계정·PUBLIC·`mafest_owner` 는 접근할 수 없다.
  - API 에는 이 역할의 Secret 을 연결하지 않는다(검사기가 API YAML 안의 `mafest-migrator`·`mafest-db-owner`·`mafest-session-migrate-db`·`mafest-db-session-migrator`·`PGURL_SESSION_MIGRATE` 를 거부한다).
- 권한: DB 접속(CONNECT)만 `db/grants/mafest_roles.sql` 이 준다. 스키마 USAGE, `search_runs`·`confirm_sessions`·`confirm_submissions` 의 SELECT/INSERT/UPDATE, `schema_migrations` 의 SELECT 는 마이그레이션 CLI(`--apply --app-role mafest_session`)의 APP_GRANTS 가 준다. DELETE 는 주지 않는다.
- 연결 예산(선언 값 기준 계산이며 실측이 아니다): Pod당 SQL 풀 4 + AGE 풀 2 + 세션 풀 2 = 8. 롤링 중 최대 3 Pod → 24, `max_connections` 64 의 절반(32) 이하다. 나머지는 적재·마이그레이션 Job, exporter, 운영 접속, 예약 연결용이다.
  검사기가 `(replicas + maxSurge) × 세 풀의 합 × 2 ≤ max_connections` 를 계산한다. 세션 풀은 첫 사용 때 연결하므로 실제 사용량은 이보다 작을 수 있다.

## 4. 마이그레이션과 배포 순서

순서: **권한·Secret 준비 → 마이그레이션 완료 및 버전 확인 → API → 웹.** (실행 명령은 §11, 아직 실행하지 않았다.)

1. 앱 CLI 는 `python -m mafest.session.migrate (--apply [--app-role R] | --check)` 이다. DSN 은 인자가 아니라 환경변수(또는 파일) `PGURL_SESSION_MIGRATE` 로 읽는다. 종료 코드는 0 정상 / 1 오류 / 2 `--check` 에서 미적용 버전 있음이다.
   역할을 만들지 않고 GRANT 만 하므로 managed role 이 먼저 있어야 한다. 최신 버전은 1, 버전 1 체크섬은 `sha256:2ff88fce82b07dc8d1da8ad4731ecf3d803f34b7492cf833b6b99f9fc5257f42` 이며 CLI 가 적용된 체크섬을 코드와 대조한다.
   `--check` 는 `--app-role` 권한을 검증하지 않는다. 권한은 `--apply` 출력과 DB 쪽 확인으로 따로 본다.
2. 마이그레이션 전 **읽기 전용 사전 점검**(`db/grants/mafest_session_precheck.sql`)이 `mafest_confirm` 스키마 상태를 보고한다. 스키마가 이미 있으면 소유권을 바꾸지 않고 소유자·객체 소유자·검색 계정/PUBLIC 접근을 보고한 뒤 멈춘다(없거나 `mafest_session_migrator` 소유일 때만 진행).
   `mafest_deploy_order.py` 도 Job 생성 전에 이 상태를 읽는다.
3. 사람이 마이그레이션 Job 을 **따로** 만든다(`mafest-app` 네임스페이스, 라벨 `mafest-loader` — 기존 적재 Job 패턴과 NetworkPolicy 재사용, DSN 은 `mafest-session-migrate-db`). Argo hook·sync wave 에 맡기지 않는다 — 선택 Sync 는 hook 을 실행하지 않고, 서로 다른 Application 의 wave 숫자는 선행을 보장하지 않는다.
4. Job 이 Complete 이고 버전이 기대와 같으며, 이어서 **유효 권한 검사**(`db/grants/mafest_session_check.sql`)가 통과할 때만 API 선택 Sync 를 요청한다.
   이 검사는 `has_*_privilege`(역할 상속·PUBLIC 포함), PUBLIC ACL, 역할 멤버십, 마이그레이션 역할의 기본 권한 부재를 확인한다: `mafest_session` 은 필요한 SELECT/INSERT/UPDATE 만 가능하고 DELETE·DDL 은 불가, `mafest_runtime`·`mafest_owner`·PUBLIC 은 세션 스키마·테이블에 접근 불가. `scripts/mafest_deploy_order.py` 가 이 순서를 가짜 실행기로 검사한다(실패·미확인이면 Sync 미요청).
5. 롤백: 앱 롤백과 DB 롤백은 다르다. 구·신 앱이 공존하므로 비파괴 확장을 기본으로 하고, 이미지 SHA를 되돌리는 것을 테이블 복구라고 부르지 않는다.
   - 기능만 끄기: Deployment 의 `MAFEST_LLM_INTENT` 를 `"0"` 으로 되돌린 선언을 API 선택 Sync 한다. 세션 Secret 참조와 풀 설정은 그대로 두어도 된다.
   - 이전 이미지로 복귀: API 이미지를 직전 승인 digest(`deploy/approved-sync.md` 의 직전 SHA)로 되돌려 Sync 한다. 이전 이미지는 모르는 env 를 무시한다.
   - **어느 경우에도 `mafest_confirm` 스키마·테이블·`mafest_session`·`mafest_session_migrator` role·Secret 은 삭제하지 않는다.** 되돌린 뒤 다시 켤 때 진행 중이던 세션과 멱등 기록을 잃지 않기 위해서다.
6. 전제(미확인): `mafest-app` 에 비공개 이미지 pull Secret `mafest-ghcr` 가 있다(기존 적재 Job 과 같다). Job 은 `mafest-app` 에서 돌므로 `mafest-data` 로 복사할 필요가 없다.

## 5. 정리 CronJob

**첫 배포에서는 활성화하지 않는다.** `suspend: true`, 기본 렌더 제외. 앱 CLI 는 `python -m mafest.session.cleanup [--batch N] [--max-batches N] [--dry-run]` 이고 DSN 은 `PGURL_SESSION_CLEANUP` 으로 읽는다(정리 전용 role 은 `migrate --apply --cleanup-role` 로 SELECT·DELETE 를 준다). 켜기 전에 정리 role·Secret 을 정하고 `--dry-run` 으로 대상을 먼저 본다. API 에는 정리 기능이 없어 끄면 행이 쌓이지만, 만료 판정은 읽는 시점에 하므로 정합성 문제는 아니다(용량 회수용). 주기 5분, 세션 만료 후 1시간, 완료/실패 턴 24시간은 **정책 후보**이며 멱등 응답 보존·세션 자격 만료·감사와 함께 앱이 확정한다. 앱이 지켜야 할 것: 삭제 가능 조건 확인과 삭제를 한 트랜잭션에서(잠금 후 재검사), running·유효 lease·진행 중 자식 턴·재전송 보존 기록 제외, cascade 로 active 턴이 사라지지 않음, 상태 전이는 앱만. PostgreSQL DELETE 에는 LIMIT 이 없으므로 앱이 배치 삭제 함수/CLI 또는 키를 고르는 CTE 방식을 제공한다. `concurrencyPolicy: Forbid` 는 DB 잠금이 아니다.

## 6. 세션·lease 설정

앱 정본(`config.py`)에는 `MAFEST_SESSION_TTL_S`, `MAFEST_TURN_LEASE_TTL_S`, `MAFEST_TURN_LEASE_RENEW_S` 라는 설정이 **없다.** 이전 초안의 후보 값을 쓰지 않으며 Deployment 에도 넣지 않는다.
앱이 실제로 읽는 값은 다음과 같고 모두 기본값을 쓴다: 확인 대기 세션 수명 `MAFEST_CONFIRM_TTL_S`(600초), 완료 응답 재전송 보관 `MAFEST_REPLAY_RETAIN_S`(3600초, 실제 보관은 `max(보관, 세션 수명 + 요청 시한 + 60)`).
lease 는 코드 고정이다(`요청 시한 + 10초`). 선언에서 바꾸지 않는다. 장애 감지 시간 보장은 여전히 약속하지 않으며(DB 지연·GC·재접속 포함) 갱신·fencing 은 앱 책임이다.
초기 활성화 설정은 Deployment 에 평문 값으로 둔다: `MAFEST_LLM_INTENT=1`, `MAFEST_LLM_STRUCTURED=1`, `MAFEST_LLM_RETRIES=0`, `MAFEST_LLM_SUMMARY=0`, `MAFEST_LLM_SUGGEST=0`, `MAFEST_SESSION_POOL_MAX=2`.
앱은 켬/끔을 정확히 `"1"`/`"0"` 으로만 읽는다(`true` 는 꺼짐). 요약·제안의 앱 기본값은 켜짐이라 끄려면 `"0"` 을 명시해야 한다. `PGURL_SESSION` 이 없거나 `MAFEST_SESSION_KEY` 가 32바이트 미만이면 앱이 기동하지 못한다.
세션 DB 는 `/healthz`·`/readyz` 에 포함되지 않아, DB 가 죽어 있어도 Pod 는 Ready 이고 첫 확인 요청에서 실패한다. 모델 주소·이름(`MAFEST_LLM_BASE_URL`, `MAFEST_LLM_MODEL`)은 기존 선언을 그대로 쓴다.

## 7. 관측

- 수집 경로는 기존 `PodMonitor/mafest-api`(`/metrics`, 30초)와 `mafest-allow-api-metrics` 로 이미 연결돼 있다. 새 수집기를 만들지 않았다.
- 후보 지표(이름은 앱이 정한다): 턴 처리 결과, lease 만료/갱신 실패, 멱등 replay, 충돌, 세션 정리, 단계별 LLM 시도 수. 라벨은 닫힌 값만(세션 ID·턴 키·질문·토큰·상품명 금지). 아직 지표가 없으므로 쿼리를 배포 대상에 넣지 않았다. 알림 규칙은 만들지 않았다.
- vLLM 요청 카운터 이름은 보존된 자료에서 찾지 못해 **미확인**이다. 실제 `/metrics` 읽기가 승인되면 확인한다. vLLM 전체 카운터는 공유 엔진의 보조 증거이며 증가량 1을 중복 생성 판정으로 쓰지 않는다. 동시 중복 제출 시험의 주 증거는 같은 멱등 키의 DB 접수·소유자·응답 replay·앱의 단계별 시도 기록이다.

## 8. 장애 시험 도구 사용 (E0만 구현)

| 모드 | 동작 | 이번 실행 |
| --- | --- | --- |
| `--offline`(기본) | 계획·판정 기준 출력 | 실행함(접속 0회) |
| `--check --expect-context <이름>` | get/config 만 호출. api 2개 Ready·다른 노드, CNPG 2개 Ready, Primary·Replica, 측정용 Pod 선정 | 가짜 kubectl로만 |
| `--verify-delete --expect-context <이름> --test-namespace mafest-fault-test-… --confirm <같은 이름> --verification-out <새 파일>` | 테스트 네임스페이스의 더미 Pod(Pending, 스케줄러 없음)로 삭제 조건 세 경우 검증 후 기록 저장 | 가짜 kubectl로만 |
| `--run E0 --confirm E0 --target-uid <UID> --inputs <json> --out-dir <새 폴더> --expect-context <이름> --delete-verification <기록>` | 사전 점검 재통과 후 Primary Pod 강제 삭제 요청 1회와 측정 | 가짜 kubectl로만 |

**context 고정**: 장애 도구와 Secret 전달 도구의 모든 kubectl 호출에는 `--context <승인값>`이 항상 붙는다(래퍼 한 곳). 정적 검사기가 AST로 "관문을 지나지 않는 kubectl 호출"을 막는다.

**삭제 방식**: `kubectl delete --raw /api/v1/namespaces/mafest-data/pods/<이름> -f <DeleteOptions>`. 본문의 `preconditions`에 **주입 직전 재조회한** `uid`와 `resourceVersion`을 모두 넣는다. 서버가 409를 돌려주면 재시도 없이 "주입 취소"로 기록한다. 같은 이름으로 재생성된 다른 Pod는 지워지지 않는다. Pod 상태가 바뀌어 resourceVersion이 달라진 정상 상황도 409가 될 수 있고, 이는 시험 실패가 아니라 주입 취소다.
- **본문이 실제로 서버에서 지켜지는지는 로컬에서 확인할 수 없다.** 로컬에서는 `kubectl delete --raw`가 `-f` 파일 하나를 본문으로 받는다는 점(파일 둘이면 "single local file" 오류)만 확인했다. 그래서 `--verify-delete`가 틀린 UID → 409·Pod 유지, 틀린 resourceVersion → 409·Pod 유지, 정상 조건 → 수락·Pod 삭제를 확인해 기록(kubectl·서버 버전 포함, 유효 24시간, 같은 context)을 남긴다. **이 기록이 없거나, 통과하지 않았거나, 낡았거나, 버전이 다르면 DB 대상 `--run`은 "준비 안 됨"(종료 코드 3)으로 중단한다. 검증이 실패했을 때 이름 삭제로 우회하는 옵션은 없다**(UID·resourceVersion 보호를 없애기 때문이며 `--run`의 kubectl 가드도 이름 삭제를 거부한다).
- `--verify-delete`는 더미 Pod를 만들고 지우는 **실제 변경**이다. 사용자 승인 전에는 실행하지 않았고 이번 작업에서도 가짜 kubectl로만 시험했다. `mafest-fault-test` 접두어 네임스페이스에서만 동작하고 네임스페이스를 만들지 않는다. 더미 Pod는 도중에 실패해도 우리가 만든 이름만 지운다.

**LLM 호출 상한(코드로 증명한 것만 인정)**: 2026-10-14의 관측(286건 평균 7ms, 같은 시간대 vLLM에 api발 요청 없음)은 근거로 쓰지 않는다. 요청당 호출 수는 이미지·생성 설정·질문에 따라 달라지므로, 경로마다 "그 이미지의 코드에서 LLM 호출 지점에 도달할 수 있는가"를 코드로 추적한 결과만 상한으로 인정한다. 결과는 `scripts/fault/llm-call-basis.json`에 이미지 digest, 검토 커밋, 진입점, 호출 경로, 분기 조건, 설정 의존과 함께 기록한다.
- **`/v1/search`는 도달 가능하다(상한 미정, E0 제외).** `run_search`는 스트림과 공유하는 본체이며 `stages.answer`(요약·후속 질문: `expand_answer`, 짧은 답: `_short_answer` → `generate`)와 `stages.suggest`를 부른다. `MAFEST_LLM_SUMMARY`·`MAFEST_LLM_SUGGEST` 기본값은 켜짐이고 api 매니페스트가 이를 지정하지 않는다. 재시도 기본 1회. `test_v1_search.py:348`은 이 경로 한 건의 `llm_calls=2`를 단정한다. "요약·후속 질문은 다른 경로에서만 실행된다"는 가설은 코드로 반박됐다.
- **`GET /v1/products/{domain}/{product_id}`는 도달 불가(상한 0).** `products.py` → 도메인 키 표 → `pg.get_by_id`(DB 한 건 조회) → `build_detail` → `base_dates`(DB). 어느 분기에도 LLM 호출이 없고 생성 설정도 읽지 않는다. 동적 관찰(`scripts/fault/proof/`)에서 상세 조회 테스트 40건이 LLM 호출 함수를 0회 실행했고, 같은 관찰이 검색 테스트에서는 호출을 잡았다(양성 대조). **E0 대상은 이 경로다.**
- 증명은 이미지 digest `…5f8a8c6f…`(검토 커밋 `c345fbf2`)에 대한 것이다. **digest가 바뀌면 `--run`은 다시 "준비 안 됨"이 된다.** 단, digest ↔ 커밋 대응은 배포 선언 주석과 D06 조회 결과를 이은 것이고 빌드 출처는 검증하지 못했다(`provenance_verified: false`). `--check`와 `--run`이 이 사실을 출력한다.
- 상세 조회는 검색과 요청 경로가 달라 **과거 검색 기준값과 동일 조건 비교가 아니다.** 입력의 `path`는 실제로 존재하는 상품의 공개 도메인 키와 id를 사람이 채우며(예시 파일은 null이라 거부된다) 공개 문서에는 실제 id를 남기지 않는다. 쿼리 문자열이 있거나 패턴에 맞지 않는 경로는 거부한다.
- 예산: `gpu_call_cap`은 `계획 요청 수 × 증명된 상한`과 **같아야 한다.** 작으면 예산 초과로, 크면 감시 기준이 느슨해지는 오입력으로 거부한다. 상품 상세는 상한이 0이므로 `gpu_call_cap`은 0만 허용된다.
- 연속 실패 중단 기준: `abort_after_consecutive_failures × interval_s`(초)는 `recovery_timeout_s` 이상이어야 한다. 측정하려는 것이 끊김 시간이므로, 복구를 기다리기로 한 시간보다 먼저 측정을 접는 설정은 거부한다. 예시 파일은 240회 × 0.5초 = 120초 = `recovery_timeout_s`다. 이 기준이 주입 뒤 남은 측정 시간보다 길면 중단 기준이 사실상 비활성이라는 경고를 `--check`·`--run`이 출력한다(거부하지는 않는다).
- **설정 확인 불가는 차단한다**: api 컨테이너에 `envFrom`이 있거나, 호출 수에 영향을 줄 수 있는 설정(`MAFEST_LLM_SUMMARY`/`SUGGEST`/`RETRIES`, `LLM_USE_MOCK`, `MAFEST_LLM_MODEL`, `MAFEST_LLM_BASE_URL`)이 `valueFrom`이면 값을 알 수 없으므로 "unset"으로 보지 않고 시작하지 않는다(Secret/ConfigMap 내용은 읽지 않는다). 설정과 무관한 `valueFrom`(예: `PGURL`)은 막지 않는다.
- **vLLM 카운터(`vllm:request_prompt_tokens_count` 합)**:
  - 읽기 검증: 읽기 명령의 종료 코드가 0이 아니거나, 값이 유한한 0 이상 실수가 아니거나(`nan`·`inf`·음수), 지표가 없으면 거부한다. 사전 읽기가 실패하면 시작하지 않는다.
  - **측정 중 주기 확인**(`llm_counter_poll_s`, 기본 10초): 증가량이 `gpu_call_cap`을 넘거나, 값이 줄거나(재시작·리셋 → 관측 불연속), 읽기가 3회 연속 실패하면 측정을 멈추고 아직 안 보낸 장애 주입을 취소한다. 단일 실패는 미확인 구간으로 기록하고 판정을 "무효 표시"로 만든다.
  - 사후에 값이 늘었거나 줄었거나 읽지 못하면 판정은 "무효 표시"다.
  - **예방이 아니다.** 이 감시는 이미 나간 호출을 되돌리지 못하고 피해를 한도 안에서 멈출 뿐이다. 호출 예방은 위의 코드 증명(도달 불가 경로 사용)뿐이다.
  - **vLLM Pod 신원 확인**: `--check`와 `--run` 시작 시 `persona-inference`의 vLLM Pod(정확히 1개, Ready)의 이름·**UID**·컨테이너 **재시작 횟수**를 기록한다(`--run`은 `plan.json`의 `vllm_pod`, 종료 시 `summary.json`의 `vllm_pod.before/after/changed`). Pod가 없거나 둘 이상이거나 Ready가 아니면 시작하지 않는다. 측정 중에는 카운터를 읽을 때마다 앞뒤로 신원을 다시 읽어, UID 또는 재시작 횟수가 시작 때와 다르거나 Pod가 하나로 특정되지 않으면 **카운터 값과 무관하게** 관측 불연속으로 보고 측정을 멈추고 주입을 취소한다. 리셋 직후 카운터가 우연히 이전 값 이상으로 올라가도 감소 검사만으로는 놓치기 때문이다. 재시작 횟수까지 보는 이유는 컨테이너만 재시작하면 UID는 그대로인데 카운터는 리셋되기 때문이다. 종료 후에도 신원을 다시 비교한다.
  - **전제(실행 전 안내, `--offline`·`--check`·`--run`이 출력)**: 카운터는 vLLM 엔진 전체 값이라, 측정 중 이 실험 외의 LLM 요청(웹, 다른 api Pod, 다른 클라이언트의 검색·스트림·설명 호출)이 있으면 증가가 감지되어 실험이 중단되거나 무효로 표시된다. 측정 전에 트래픽이 없는지 사람이 확인한다.
  - 카운터 이름 `vllm:request_prompt_tokens_count`는 2026-10-14 04:05 KST 측정에서 **vLLM Pod 안의 `/metrics`로 실제 읽혔다(값 20, 21, 사용자 제공 기록)**. 이어서 2026-10-14 15:57 KST에 **api 컨테이너에서 `persona-vllm` Service를 거쳐 같은 카운터를 읽는 데 성공했다(값 0.0, 사용자 제공 기록)**. 그 사이 값이 20·21에서 0.0이 된 것은 vLLM 재시작에 의한 카운터 리셋이다. 앞서의 `Connection refused`는 vLLM Pod가 준비되지 않았기 때문이었다(GPU 노드가 약 46분간 NotReady였고, 복귀 후 vLLM은 컨테이너 시작부터 Ready까지 3분 38초가 걸렸다). 이 경로가 `--run` 시점에도 되는지는 사전 읽기가 다시 확인하며, 못 읽으면 시작하지 않는다.

**중단과 정리**: 측정 출력이 깨지거나 예외가 나면 `finally`에서 먼저 주입 취소 플래그를 세운다(주입과 같은 락을 쓰므로 "중단이 먼저면 주입 없음, 주입이 먼저면 이미 끝난 뒤"). 그 뒤 타이머 취소·측정 프로세스 종료·부분 결과 저장을 한다.

- `kubectl debug`는 쓰지 않는다(ephemeral container 생성은 읽기 전용이 아니다). 측정은 장애 대상과 **다른 노드의 기존 api Pod에 `kubectl exec`**로 한다. 측정은 netshoot 같은 디버그 이미지가 아니라 **`mafest-api` 컨테이너(`-c api`)**에서 실행하며, `--run`은 시작 전에 같은 컨테이너에서 `python3 --version`을 실행해 확인하고 없으면 장애를 넣기 전에 중단한다(`summary.json`의 `measurement_python`에 기록). 운영 api 컨테이너의 `python3`는 2026-10-14 15:57 KST 확인에서 **Python 3.12.15**였다(사용자 제공 기록). `--run` 시점의 확인은 시작 전에 다시 한다. 측정 요청은 그 Pod의 `127.0.0.1:8000`으로 가므로 측정이 그 Pod의 부하가 된다.
- 기록: `plan.json`(대상 UID·노드·입력·LLM 상한 증명·전제·삭제 방식), `requests.csv`(UTC, 순번, HTTP, 응답 ms, 오류 분류, 턴 상태), `roles.json`(2초 간격 CNPG 역할), `summary.json`(실패 건수·구간·최대 응답·회복 시간·시계 오프셋·vLLM 카운터·DB 보조 관측·판정), `kubectl_calls.json`. E0 판정은 **수치 기록만**이며 vLLM 증가 시 무효 표시다.
- 시계: 기록은 UTC, 측정 Pod와 로컬의 시계 오프셋을 기록한다. 노드 간 시계 오차는 관측하지 못한다. 회복 시간은 2초 폴링 해상도다.
- Pod 강제 삭제 요청은 프로세스 종료·fencing 보장이 아니다. 응답이 유실되면 "미확인"으로 기록하고 재전송하지 않는다.
- E1~E5는 앱 계약이 없어 `--run`이 "준비 안 됨"으로 종료한다. 노드·VM 정지는 `--run` 대상이 아니다(사용자 수동 절차).
- `xact_commit`과 `pg_stat_activity` 집계는 보조 관측이다. 쿼리 원문·DSN은 저장하지 않는다.

## 9. 앱·웹과 합의할 목록

확정됨(앱 정본 기준): schema `mafest_confirm` 과 테이블 4개, 마이그레이션 CLI·버전 1·체크섬, 환경변수 이름·검증, 세션 role·Secret·풀 크기(이 문서 §3, 플랫폼 결정), lease 코드 고정.
남음: 이미지 digest, 정리 보존 기간·삭제 조건·정리 role, 메트릭 이름·타입·라벨, 외부 생성(vLLM) 결과 불명확 시 처리, DB 장애 시 RPO(비동기 복제에서 손실 0 약속 여부), `db_pool.py` 주석의 현재 운영(rw 단일) 반영.
외부 vLLM 추론은 앱 DB commit 과 한 트랜잭션이 아니므로 "정확히 한 번"을 플랫폼이 약속하지 않는다.

## 10. 후속 승인 순서

앱·웹 계약 확정 → 로컬 도구 검토 → 별도 읽기 승인과 `--check` → Secret 전달 / 권한 / 마이그레이션 / 배포 각각의 변경 승인 → 정상 경로 검증 → 별도 E0 승인. E1~E5 는 앱 기능·관측·복구 계약 완료 뒤 별도 승인. `--offline` 성공만으로 apply 나 E0 실행을 권하지 않는다.

CP의 `~/mafest-api-db.backup.yaml` 은 이번에 열지도 지우지도 않았다. 새 접속·권한이 적용되고 정상 동작과 복구 경로가 확인된 뒤 사용자가 정확한 경로와 보존 필요성을 검토해 따로 정리한다. 백업 파일 삭제와, 이미 노출된 자격의 회전 필요성은 별개로 판단한다.

## 11. 이미지 digest 와 운영 적용 순서 (런북 확정본 — 운영 적용·권한 검사는 아직 실행하지 않았다)

**이미지 digest** — 게시된 digest 를 반영했다. 추측으로 채우지 않고, 바꿀 때는 아래 위치를 함께 바꾼다.

| 값 | 상태 | 위치 |
| --- | --- | --- |
| API 이미지 (`mafest-app@sha256:6523b6de…8c62e0`) | 반영함 | `kustomize/base/mafest-app/api-deployment.yaml`, `scripts/validate-mafest-app-manifests.sh` 의 `APPROVED_API_IMAGE` |
| 마이그레이션 Job 이미지 (API 와 같은 digest) | 반영함 | `drafts/migration-job.yaml.draft`. 적용 때 `kustomize/base/mafest-load/job-session-migrate.yaml` 로 옮기고 kustomization 의 주석 한 줄을 켠다 |
| 웹 이미지 (`mafest-web@sha256:b2f40f4e…2f152`) | 반영함 | `kustomize/base/mafest-app/web-deployment.yaml`, 같은 검사기의 `APPROVED_WEB_IMAGE` |
| DB 이미지(CNPG 포함) | **변경 없음** | `kustomize/base/mafest-db/cluster.yaml` |
| 호출 상한 증명의 digest | **남음** | `scripts/fault/llm-call-basis.json` 은 옛 API digest 에 묶여 있어 새 digest 에서는 무효다. 장애 시험 전에 다시 만든다 |
| 정리 CronJob 의 role·Secret·digest | **남음** | 정리를 켜는 시점에 |

**운영 적용 순서** (모두 사람이 승인한 뒤 한 단계씩. 모든 명령은 승인한 context 와 정확한 namespace 를 직접 적는다. 터미널 기본 context·namespace 에 의존하지 않는다.
`<승인한-context>` 는 적용 직전에 사람이 정한 kubectl context 이름으로 바꾼다. cnpg 플러그인 명령은 `--context` 같은 전역 플래그를 플러그인 이름 **뒤**에 둔다. 플러그인 앞에 두면 kubectl 이 플러그인을 찾지 못한다):

0. context·namespace 확인(읽기 전용) — 이후 모든 명령은 같은 context 를 쓴다. 현재 API 이미지 digest 를 **롤백용으로 기록**한다.
   - `kubectl --context <승인한-context> -n mafest-app get deployment mafest-api -o jsonpath='{.spec.template.spec.containers[0].image}'`
   - `kubectl --context <승인한-context> -n mafest-data get cluster.postgresql.cnpg.io mafest-db`
1. Secret·전용 역할 준비 — 먼저 Secret 을 만든다. 값은 출력하지 않는다. 비밀번호·DSN·키는 0600 임시 파일에 두고 끝나면 지운다.
   - `kubectl --context <승인한-context> -n mafest-data create secret generic mafest-db-session --type=kubernetes.io/basic-auth --from-literal=username=mafest_session --from-file=password=<0600 파일>`
   - `kubectl --context <승인한-context> -n mafest-data create secret generic mafest-db-session-migrator --type=kubernetes.io/basic-auth --from-literal=username=mafest_session_migrator --from-file=password=<0600 파일>`
   - `kubectl --context <승인한-context> -n mafest-app create secret generic mafest-api-session --from-file=PGURL_SESSION=<0600 파일> --from-file=MAFEST_SESSION_KEY=<0600 파일>` (`mafest_session` 계정 DSN, 새 난수 32바이트 이상, 두 Pod 공용)
   - `kubectl --context <승인한-context> -n mafest-app create secret generic mafest-session-migrate-db --from-file=PGURL=<0600 파일>` (`mafest_session_migrator` 계정 DSN, 마이그레이션 Job 전용)
1b. `mafest-db` Application 에서 Cluster 한 건 선택 Sync(`argocd/README.md` 절차) 뒤 managed role 확인: `kubectl --context <승인한-context> -n mafest-data get cluster.postgresql.cnpg.io mafest-db`
1c. 역할 권한: `kubectl cnpg psql mafest-db --context <승인한-context> -n mafest-data -- -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_roles.sql`
2. 읽기 전용 사전 점검: `kubectl cnpg psql mafest-db --context <승인한-context> -n mafest-data -- -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_session_precheck.sql` — `ok absent` 또는 `ok owned` 일 때만 계속한다. 그 밖이면 소유권을 바꾸지 않고 출력만 보고한다.
3. 마이그레이션: Job 초안(digest 반영됨)을 `kustomize/base/mafest-load/job-session-migrate.yaml` 로 옮기고 kustomization 의 주석 한 줄을 켠 뒤 적용하고 결과를 확인한다.
   - `kubectl --context <승인한-context> -n mafest-app apply -k kustomize/base/mafest-load`
   - `kubectl --context <승인한-context> -n mafest-app wait --for=condition=complete job/mafest-session-migrate --timeout=300s`
   - `kubectl --context <승인한-context> -n mafest-app logs job/mafest-session-migrate` (적용 출력과 `--check` 성공 확인)
   - 확인 뒤 `kubectl --context <승인한-context> -n mafest-app delete job mafest-session-migrate` 로 Job 을 지우고 kustomization 은 다시 비운다.
4. 읽기 전용 유효 권한 검사: `kubectl cnpg psql mafest-db --context <승인한-context> -n mafest-data -- -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_session_check.sql` — `세션 유효 권한 검사 통과` 이고 종료 코드가 0 일 때만 계속한다.
5. (2~4 가 모두 통과한 뒤에만) API 선택 Sync(`mafest-api` Deployment 한 건) → 두 Pod Ready 와 롤링 확인: `kubectl --context <승인한-context> -n mafest-app rollout status deployment/mafest-api`. 순서 도구: `python3 scripts/mafest_deploy_order.py --offline`.
6. API 가 정상인 것을 확인한 뒤 웹 선택 Sync → `kubectl --context <승인한-context> -n mafest-app rollout status deployment/mafest-web`.
7. 롤백은 §4(0단계에서 기록한 이전 API digest 로 되돌린다. 세션 테이블·역할·Secret 은 지우지 않는다).
