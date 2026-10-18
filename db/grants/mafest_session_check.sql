-- 세션 스키마(mafest_confirm)의 마이그레이션 후 "유효 권한" 확인. 읽기 전용이며 아무것도 바꾸지 않는다.
--
--   kubectl --context <승인한-context> -n mafest-data exec -i "$PRIMARY" -- psql -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_session_check.sql
--   (PRIMARY 는 cnpg.io/instanceRole=primary 라벨의 Pod 이름이다. 운영 서버에는 cnpg 플러그인이 없어 exec 로 실행한다.)
--
-- 판정은 ACL 문자열이 아니라 has_*_privilege 로 한다. 이 함수들은 역할 상속·멤버십과 PUBLIC 권한을 모두 반영한 실제 유효 권한을 돌려준다.
-- 그래서 owner 의 기본 권한, PUBLIC, 다른 역할 상속을 통해 새는 접근도 잡는다. 추가로 PUBLIC ACL(aclexplode)·역할 멤버십·
-- 마이그레이션 역할의 기본 권한(pg_default_acl)을 따로 본다.
--
-- 출력은 "ok <검사>" / "FAIL <검사>" NOTICE 와 마지막 요약뿐이다. FAIL 이 하나라도 있으면 예외로 끝난다(psql 종료 코드 3).
-- 전체를 읽기 전용 트랜잭션으로 감싸고 ROLLBACK 한다.
\set ON_ERROR_STOP on
BEGIN READ ONLY;

DO $check$
DECLARE
    failures int := 0;
    schema_name constant text := 'mafest_confirm';
    migrator constant text := 'mafest_session_migrator';
    data_tables constant text[] := ARRAY['search_runs', 'confirm_sessions', 'confirm_submissions'];
    all_tables constant text[] := ARRAY['search_runs', 'confirm_sessions', 'confirm_submissions', 'schema_migrations'];
    t text;
    p text;
    table_count int;
BEGIN
    -- 0) 기대한 객체가 있다.
    SELECT count(*) INTO table_count FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = schema_name AND c.relkind = 'r' AND c.relname = ANY (all_tables);
    IF table_count <> cardinality(all_tables) THEN
        RAISE NOTICE 'FAIL tables-exist: 세션 테이블 % 개 중 % 개만 있다', cardinality(all_tables), table_count;
        RAISE EXCEPTION '세션 테이블이 없다 — 마이그레이션이 끝났는지 먼저 본다';
    END IF;
    RAISE NOTICE 'ok tables-exist: 테이블 % 개', table_count;

    -- 1) 소유권: 스키마와 모든 객체(인덱스 포함)가 세션 마이그레이션 역할 소유다. 상품 owner 가 아니다.
    IF (SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = schema_name) <> migrator THEN
        RAISE NOTICE 'FAIL owner-schema: 스키마 소유자가 % 이(가) 아니다', migrator; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok owner-schema';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = schema_name AND c.relowner::regrole::text <> migrator) THEN
        RAISE NOTICE 'FAIL owner-objects: % 소유가 아닌 객체가 있다', migrator; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok owner-objects';
    END IF;

    -- 2) 세션 API 계정(mafest_session): 필요한 권한만.
    IF NOT has_database_privilege('mafest_session', current_database(), 'CONNECT')
       OR NOT has_schema_privilege('mafest_session', schema_name, 'USAGE') THEN
        RAISE NOTICE 'FAIL session-usage: 접속 또는 스키마 USAGE 가 없다'; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok session-usage';
    END IF;
    FOREACH t IN ARRAY data_tables LOOP
        FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE'] LOOP
            IF NOT has_table_privilege('mafest_session', format('%I.%I', schema_name, t), p) THEN
                RAISE NOTICE 'FAIL session-allow: % 에 % 가 없다', t, p; failures := failures + 1;
            END IF;
        END LOOP;
    END LOOP;
    IF NOT has_table_privilege('mafest_session', format('%I.%I', schema_name, 'schema_migrations'), 'SELECT') THEN
        RAISE NOTICE 'FAIL session-allow: schema_migrations SELECT 가 없다'; failures := failures + 1;
    END IF;
    FOREACH t IN ARRAY all_tables LOOP
        FOREACH p IN ARRAY ARRAY['DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
            IF has_table_privilege('mafest_session', format('%I.%I', schema_name, t), p) THEN
                RAISE NOTICE 'FAIL session-deny: % 에 % 가 있다', t, p; failures := failures + 1;
            END IF;
        END LOOP;
    END LOOP;
    FOREACH p IN ARRAY ARRAY['INSERT', 'UPDATE'] LOOP
        IF has_table_privilege('mafest_session', format('%I.%I', schema_name, 'schema_migrations'), p) THEN
            RAISE NOTICE 'FAIL session-deny: schema_migrations 에 % 가 있다', p; failures := failures + 1;
        END IF;
    END LOOP;
    -- DDL 불가: 스키마 CREATE, DB CREATE(스키마 생성), 임시 테이블.
    IF has_schema_privilege('mafest_session', schema_name, 'CREATE')
       OR has_database_privilege('mafest_session', current_database(), 'CREATE')
       OR has_database_privilege('mafest_session', current_database(), 'TEMPORARY') THEN
        RAISE NOTICE 'FAIL session-ddl: DDL 이 가능한 권한이 있다'; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok session-ddl: DDL 불가';
    END IF;

    -- 3) 검색 계정(mafest_runtime)과 상품 owner: 세션 스키마·테이블에 어떤 접근도 없다(상속·PUBLIC 포함).
    FOREACH p IN ARRAY ARRAY['mafest_runtime', 'mafest_owner'] LOOP
        IF has_schema_privilege(p, schema_name, 'USAGE') OR has_schema_privilege(p, schema_name, 'CREATE') THEN
            RAISE NOTICE 'FAIL isolated-schema: % 가 세션 스키마에 접근할 수 있다', p; failures := failures + 1;
        ELSE
            RAISE NOTICE 'ok isolated-schema: %', p;
        END IF;
        FOREACH t IN ARRAY all_tables LOOP
            IF has_any_column_privilege(p, format('%I.%I', schema_name, t), 'SELECT,INSERT,UPDATE,REFERENCES')
               OR has_table_privilege(p, format('%I.%I', schema_name, t), 'DELETE,TRUNCATE,TRIGGER') THEN
                RAISE NOTICE 'FAIL isolated-table: % 가 % 에 접근할 수 있다', p, t; failures := failures + 1;
            END IF;
        END LOOP;
    END LOOP;

    -- 4) PUBLIC: 스키마·테이블 ACL 에 grantee 0(PUBLIC)이 없다. NULL ACL 은 기본 ACL 로 풀어서 본다.
    IF EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
                WHERE n.nspname = schema_name AND a.grantee = 0)
       OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
                         aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                   WHERE n.nspname = schema_name AND c.relkind IN ('r', 'p', 'v', 'm') AND a.grantee = 0) THEN
        RAISE NOTICE 'FAIL public-acl: PUBLIC 에 세션 스키마·테이블 권한이 있다'; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok public-acl';
    END IF;

    -- 5) 역할 멤버십(상속 경로): 검색 계정이 세션 역할의 멤버가 아니고, 세션 API 계정이 DDL 역할·상품 owner 의 멤버가 아니다.
    IF pg_has_role('mafest_runtime', 'mafest_session', 'MEMBER')
       OR pg_has_role('mafest_runtime', migrator, 'MEMBER')
       OR pg_has_role('mafest_session', migrator, 'MEMBER')
       OR pg_has_role('mafest_session', 'mafest_owner', 'MEMBER')
       OR pg_has_role(migrator, 'mafest_owner', 'MEMBER') THEN
        RAISE NOTICE 'FAIL role-membership: 역할 상속으로 세션 권한이 이어진다'; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok role-membership';
    END IF;

    -- 6) 마이그레이션 역할에는 기본 권한(pg_default_acl)이 없다 — 앞으로 만드는 객체도 다른 역할에 열리지 않는다.
    IF EXISTS (SELECT 1 FROM pg_default_acl WHERE defaclrole = migrator::regrole) THEN
        RAISE NOTICE 'FAIL default-acl: % 에 기본 권한이 있다', migrator; failures := failures + 1;
    ELSE
        RAISE NOTICE 'ok default-acl';
    END IF;

    IF failures > 0 THEN
        RAISE EXCEPTION '세션 유효 권한 검사 실패 %건', failures USING ERRCODE = 'P0003';
    END IF;
    RAISE NOTICE '세션 유효 권한 검사 통과';
END
$check$;

ROLLBACK;
