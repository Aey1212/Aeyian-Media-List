-- ============================================================================
-- Tests for migration 0010 — more staff roles.
-- Run with db/test.sh (applies migrations 0001..0010 to a fresh database).
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE FUNCTION pg_temp.t(label text, stmt text, expect text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN others THEN
    IF expect IS NOT NULL AND position(expect IN SQLERRM) > 0 THEN
      RETURN 'PASS | ' || label || ' | refused by ' || expect;
    END IF;
    RETURN 'FAIL | ' || label || ' | ' || SQLERRM;
  END;
  IF expect IS NULL THEN RETURN 'PASS | ' || label || ' | ok'; END IF;
  RETURN 'FAIL | ' || label || ' | succeeded, wanted refusal by ' || expect;
END $$;

CREATE FUNCTION pg_temp.eq(label text, actual text, expected text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN actual IS NOT DISTINCT FROM expected
    THEN 'PASS | ' || label || ' | ' || coalesce(actual, 'NULL')
    ELSE 'FAIL | ' || label || ' | got ' || coalesce(actual, 'NULL') || ', want ' || coalesce(expected, 'NULL') END $$;

\echo '--- staff roles'
SELECT pg_temp.eq('all roles in page order',
  (SELECT string_agg(labels -> 'en' ->> 'text', ', ' ORDER BY sort_order, code) FROM core.staff_role),
  'Original Creator, Illustrator, Director, Series Composition, Writer, Composer, Original Character Designer, Character Designer, Chief Animation Director, Art Director, Sound Director, Performer');

CREATE TEMP TABLE fx (name text PRIMARY KEY, id bigint);
INSERT INTO fx VALUES ('anime', core.create_entity('anime')), ('person', core.create_entity('person'));
CREATE FUNCTION pg_temp.id(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM fx WHERE name = p $$;

SELECT pg_temp.t('credit with a new role', format($$INSERT INTO core.staff_credit (person_id, role, target_id, target_kind) VALUES (%s, 'series_composition', %s, 'anime')$$, pg_temp.id('person'), pg_temp.id('anime')), NULL);
SELECT pg_temp.t('one person, two new roles on one work', format($$INSERT INTO core.staff_credit (person_id, role, target_id, target_kind) VALUES (%s, 'chief_animation_director', %s, 'anime')$$, pg_temp.id('person'), pg_temp.id('anime')), NULL);
SELECT pg_temp.t('unknown role still refused', format($$INSERT INTO core.staff_credit (person_id, role, target_id, target_kind) VALUES (%s, 'key_grip', %s, 'anime')$$, pg_temp.id('person'), pg_temp.id('anime')), 'staff_credit_role_fk');
