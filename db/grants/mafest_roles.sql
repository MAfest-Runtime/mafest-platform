-- mafest DB 역할 권한(문서 35 §역할 순서: 확장 → runtime 역할·CONNECT·ag_catalog USAGE·search_path·기본 권한
-- → 적재 → 기존 객체 GRANT 보정). 이 파일은 그중 "적재 전" 부분이다. 멱등이다.
--
-- 누가·어디서: Cluster mafest-db가 2/2로 뜬 뒤 superuser로 한 번 실행한다(runbooks/mafest-data, A7).
--   kubectl --context <승인한-context> -n mafest-data exec -i "$PRIMARY" -- psql -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_roles.sql
--   (PRIMARY 는 cnpg.io/instanceRole=primary 라벨의 Pod 이름이다. 운영 서버에는 cnpg 플러그인이 없어 exec 로 실행한다.)
--   ag_catalog는 확장(age)을 만든 superuser가 소유해서 owner(mafest_owner)는 여기에 GRANT를 줄 수 없다.
--   ALTER ROLE ... SET도 superuser·CREATEROLE 권한이 필요하다.
--
-- 이 파일이 하지 않는 것:
--   - 역할 생성·비밀번호: mafest_runtime은 Cluster spec.managed.roles가 Secret mafest-db-runtime으로 만든다.
--     mafest_owner는 bootstrap.initdb가 Secret mafest-db-owner로 만든다. 비밀번호를 SQL에 두지 않는다.
--   - 확장 생성: initdb postInitApplicationSQL(age·pg_trgm).
--   - 쓰기 권한: runtime에는 읽기만 준다(쓰기 거부는 mafest_runtime_check.sql로 확인한다).
\set ON_ERROR_STOP on

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mafest_owner') THEN
        RAISE EXCEPTION 'mafest_owner 역할이 없다 — initdb가 끝났는지 먼저 본다';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mafest_runtime') THEN
        RAISE EXCEPTION 'mafest_runtime 역할이 없다 — Secret mafest-db-runtime과 managed.roles 상태를 먼저 본다';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mafest_session') THEN
        RAISE EXCEPTION 'mafest_session 역할이 없다 — Secret mafest-db-session과 managed.roles 상태를 먼저 본다';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mafest_session_migrator') THEN
        RAISE EXCEPTION 'mafest_session_migrator 역할이 없다 — Secret mafest-db-session-migrator와 managed.roles 상태를 먼저 본다';
    END IF;
END
$roles$;

-- DB 접속: PUBLIC 기본 권한(CONNECT·TEMP)을 걷고 쓸 역할에만 준다.
-- cnpg_metrics_exporter는 CNPG exporter가 쓰는 역할이다. 빼먹으면 지표 수집이 끊긴다(문서 35 §DB, persona-db 운영 때 겪음).
REVOKE ALL ON DATABASE mafest FROM PUBLIC;
GRANT CONNECT ON DATABASE mafest TO mafest_owner, mafest_runtime, cnpg_metrics_exporter;
-- 세션 저장소 역할은 접속만 여기서 준다. 스키마·테이블 권한은 마이그레이션 CLI(--app-role)가 준다. TEMP·CREATE는 주지 않는다.
GRANT CONNECT ON DATABASE mafest TO mafest_session;
-- 세션 마이그레이션 역할은 접속과 스키마 생성(DB CREATE)만 받는다. 이 역할을 대상으로 한 ALTER DEFAULT PRIVILEGES 는 두지 않는다.
-- mafest_owner 의 기본 권한(아래)은 owner 가 만든 객체에만 적용되므로 이 역할이 만든 세션 테이블에는 걸리지 않는다. TEMP 도 주지 않는다.
GRANT CONNECT, CREATE ON DATABASE mafest TO mafest_session_migrator;
-- owner는 적재 중 임시 표를 쓸 수 있다. runtime에는 TEMP를 주지 않는다(읽기 전용).
GRANT TEMPORARY ON DATABASE mafest TO mafest_owner;

-- runtime이 PUBLIC 스키마에 객체를 만들지 못하게 한다(PG15+ 기본이지만 명시한다).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- cypher()·agtype이 ag_catalog에 있다. 두 역할 모두 이 스키마를 써야 한다.
GRANT USAGE ON SCHEMA ag_catalog TO mafest_owner, mafest_runtime;

-- runtime은 LOAD 'age'를 못 해서 preload(shared_preload_libraries=age)와 이 search_path를 전제로 한다
-- (mafest db_pool.AGE_SEARCH_PATH와 같은 값).
ALTER ROLE mafest_runtime SET search_path = ag_catalog, "$user", public;

-- owner가 앞으로 만드는 표·그래프 스키마를 runtime이 GRANT 없이 바로 읽게 한다(적재 도중 권한 공백 방지).
-- 범위는 실제 owner(mafest_owner)로 한정한다 — 다른 역할이 만드는 객체에는 걸리지 않는다.
ALTER DEFAULT PRIVILEGES FOR ROLE mafest_owner GRANT SELECT ON TABLES TO mafest_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE mafest_owner GRANT USAGE ON SCHEMAS TO mafest_runtime;
