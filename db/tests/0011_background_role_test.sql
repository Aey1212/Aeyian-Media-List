-- ============================================================================
-- Tests for migration 0011 — the Background appearance role.
-- Run with db/test.sh (applies migrations 0001..0011 to a fresh database).
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

\echo '--- appearance roles'
SELECT pg_temp.eq('roles in page order',
  (SELECT string_agg(labels -> 'en' ->> 'text', ', ' ORDER BY sort_order, code) FROM core.appearance_role),
  'Protagonist, Main, Supporting, Antagonist, Playable, Boss, Guest, Background');

CREATE TEMP TABLE fx (name text PRIMARY KEY, id bigint);
INSERT INTO fx VALUES ('anime', core.create_entity('anime')), ('character', core.create_entity('character'));
CREATE FUNCTION pg_temp.id(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM fx WHERE name = p $$;
INSERT INTO core.appearance (character_id, target_id, target_kind) VALUES (pg_temp.id('character'), pg_temp.id('anime'), 'anime');

SELECT pg_temp.t('a background appearance', format($$INSERT INTO core.appearance_role_link (appearance_id, role) SELECT id, 'background' FROM core.appearance WHERE character_id = %s$$, pg_temp.id('character')), NULL);
SELECT pg_temp.t('unknown role still refused', format($$INSERT INTO core.appearance_role_link (appearance_id, role) SELECT id, 'extra' FROM core.appearance WHERE character_id = %s$$, pg_temp.id('character')), 'appearance_role_link_role_fk');
