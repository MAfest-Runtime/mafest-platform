-- 세션 스키마(mafest_confirm) 마이그레이션 전 사전 점검. 읽기 전용이며 아무것도 바꾸지 않는다.
--
--   kubectl cnpg psql mafest-db --context <승인한-context> -n mafest-data -- -d mafest -v ON_ERROR_STOP=1 -f - < db/grants/mafest_session_precheck.sql
--
-- 왜 필요한가: 마이그레이션 CLI 는 `CREATE SCHEMA IF NOT EXISTS` 를 쓰므로, 스키마가 이미 다른 소유자로 있으면 조용히 이어 가다가
-- 어디서 실패할지 알 수 없다. 이 점검이 먼저 상태(소유자·객체 소유자·검색 계정/PUBLIC 접근)를 보고하고, 기대와 다르면 예외로 멈춘다.
-- 소유권을 바꾸는 문장(ALTER ... OWNER)은 어디에도 없다. 바꿀지는 상태를 본 사람이 따로 결정한다.
--
-- 결과: 스키마가 없으면 "ok absent", 세션 마이그레이션 역할이 소유하고 접근이 기대와 같으면 "ok owned"(멱등 재실행만 가능),
-- 그 밖에는 "FAIL ..." 과 예외(psql 종료 코드 3). 출력에는 역할 이름과 고정된 객체 이름만 나온다.
\set ON_ERROR_STOP on
BEGIN READ ONLY;

DO $pre$
DECLARE
    schema_owner text;
    failures int := 0;
    obj record;
    expected_owner constant text := 'mafest_session_migrator';
BEGIN
    SELECT nspowner::regrole::text INTO schema_owner FROM pg_namespace WHERE nspname = 'mafest_confirm';
    IF schema_owner IS NULL THEN
        RAISE NOTICE 'ok absent: mafest_confirm 스키마가 없다 — 마이그레이션이 새로 만든다';
        RETURN;
    END IF;

    RAISE NOTICE 'present: mafest_confirm 스키마가 이미 있다(소유자 %)', schema_owner;
    IF schema_owner <> expected_owner THEN
        RAISE NOTICE 'FAIL owner: 스키마 소유자가 % 이(가) 아니다', expected_owner; failures := failures + 1;
    END IF;

    FOR obj IN
        SELECT c.relname, c.relkind, c.relowner::regrole::text AS owner_name
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'mafest_confirm'
         ORDER BY c.relname
    LOOP
        RAISE NOTICE 'object % (%) 소유자 %', obj.relname, obj.relkind, obj.owner_name;
        IF obj.owner_name <> expected_owner THEN
            RAISE NOTICE 'FAIL object-owner: % 소유자가 % 이(가) 아니다', obj.relname, expected_owner; failures := failures + 1;
        END IF;
    END LOOP;

    -- 검색 계정·상품 owner·PUBLIC 이 세션 스키마에 접근하면 기록 노출이다.
    IF has_schema_privilege('mafest_runtime', 'mafest_confirm', 'USAGE')
       OR has_schema_privilege('mafest_runtime', 'mafest_confirm', 'CREATE') THEN
        RAISE NOTICE 'FAIL runtime-schema: 검색 계정이 세션 스키마에 접근할 수 있다'; failures := failures + 1;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'mafest_confirm' AND c.relkind IN ('r', 'p', 'v', 'm')
           AND (has_any_column_privilege('mafest_runtime', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
                OR has_table_privilege('mafest_runtime', c.oid, 'DELETE,TRUNCATE,TRIGGER'))
    ) THEN
        RAISE NOTICE 'FAIL runtime-table: 검색 계정이 세션 테이블에 접근할 수 있다'; failures := failures + 1;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
         WHERE n.nspname = 'mafest_confirm' AND a.grantee = 0
    ) OR EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
               aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
         WHERE n.nspname = 'mafest_confirm' AND c.relkind IN ('r', 'p', 'v', 'm') AND a.grantee = 0
    ) THEN
        RAISE NOTICE 'FAIL public-acl: PUBLIC 에 세션 스키마·테이블 권한이 있다'; failures := failures + 1;
    END IF;

    IF failures > 0 THEN
        RAISE EXCEPTION '세션 스키마가 기대와 다르다(% 건) — 소유권을 바꾸지 않았다. 상태를 보고하고 중단한다', failures
            USING ERRCODE = 'P0003';
    END IF;
    RAISE NOTICE 'ok owned: 기존 스키마가 % 소유이고 검색 계정·PUBLIC 접근이 없다 — 멱등 재실행만 가능', expected_owner;
END
$pre$;

ROLLBACK;
