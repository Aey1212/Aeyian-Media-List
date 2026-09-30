-- ============================================================================
-- Tests for migration 0012 — the change log.
-- Run with db/test.sh (applies migrations 0001..0012 to a fresh database).
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

CREATE TEMP TABLE fx (name text PRIMARY KEY, id bigint);
INSERT INTO fx VALUES ('anime', core.create_entity('anime'));
CREATE FUNCTION pg_temp.id(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM fx WHERE name = p $$;

\echo '--- recording changes'
SELECT pg_temp.t('a score set from the web', format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, before, after) VALUES ('web', 'set_score', %s, '/01/0001/001 Test', NULL, '{"general": 32}')$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('a clear from the terminal', format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, before, after) VALUES ('terminal', 'clear_score', %s, '/01/0001/001 Test', '{"general": 32}', NULL)$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('from the chat', format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, before, after) VALUES ('chat', 'set_take', %s, '/01/0001/001 Test', NULL, '{"body": "x"}')$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('an unknown door',      format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, after) VALUES ('email', 'set_score', %s, 'x', '{}')$$, pg_temp.id('anime')), 'change_log_via_ck');
SELECT pg_temp.t('a badly named operation', format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, after) VALUES ('web', 'Set Score', %s, 'x', '{}')$$, pg_temp.id('anime')), 'change_log_operation_ck');
SELECT pg_temp.t('a change that changes nothing', format($$INSERT INTO core.change_log (via, operation, entity_id, entity_label, before, after) VALUES ('web', 'set_score', %s, 'x', '{"general": 1}', '{"general": 1}')$$, pg_temp.id('anime')), 'change_log_changed_ck');
SELECT pg_temp.t('a label is required', format($$INSERT INTO core.change_log (via, operation, entity_id, after) VALUES ('web', 'set_score', %s, '{}')$$, pg_temp.id('anime')), 'entity_label');

\echo '--- the history outlives the entity'
DELETE FROM core.entity WHERE id = pg_temp.id('anime');
SELECT pg_temp.eq('rows kept, entity link cleared, label readable',
  (SELECT count(*) || ' rows, ' || count(entity_id) || ' linked, ' || min(entity_label) FROM core.change_log),
  '3 rows, 0 linked, /01/0001/001 Test');
