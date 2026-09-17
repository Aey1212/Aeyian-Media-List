-- ============================================================================
-- Tests for migration 0009 — latinized titles.
-- Run with db/test.sh (applies migrations 0001..0009 to a fresh database).
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
INSERT INTO fx VALUES
  ('game',   core.create_entity('game')),
  ('person', core.create_entity('person'));
CREATE FUNCTION pg_temp.id(p text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM fx WHERE name = p $$;

INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES
  (pg_temp.id('game'),   'ja', 'full', 'ペルソナ3', true),
  (pg_temp.id('game'),   'ar', 'full', 'بيرسونا 3', false),
  (pg_temp.id('person'), 'ja', 'full', '石田彰', true);
CREATE FUNCTION pg_temp.tid(p text, l text) RETURNS bigint LANGUAGE sql AS $$
  SELECT t.id FROM core.title t WHERE t.entity_id = pg_temp.id(p) AND t.lang = l AND t.title_type = 'full' $$;

\echo '--- names'
SELECT pg_temp.eq('column is latinizes_id',
  (SELECT string_agg(column_name, ', ' ORDER BY column_name) FROM information_schema.columns
    WHERE table_schema = 'core' AND table_name = 'title' AND column_name ~ '(roman|latin)'), 'latinizes_id');
SELECT pg_temp.eq('constraints renamed',
  (SELECT string_agg(conname, ', ' ORDER BY conname) FROM pg_constraint
    WHERE conrelid = 'core.title'::regclass AND conname ~ '(roman|latin)'),
  'title_latinized_latin_ck, title_latinized_not_native_ck, title_latinizes_fk, title_latinizes_self_ck');
SELECT pg_temp.eq('no "roman" name left anywhere in the database',
  (SELECT count(*)::text FROM (
     SELECT conname AS n FROM pg_constraint
     UNION ALL SELECT relname FROM pg_class
     UNION ALL SELECT attname FROM pg_attribute WHERE NOT attisdropped
     UNION ALL SELECT proname FROM pg_proc
   ) names WHERE n ~* 'roman'), '0');

\echo '--- the layer 3 rules still hold under the new names'
SELECT pg_temp.t('romaji latinizes the Japanese title', format($$INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (%s, 'ja-Latn', 'full', 'Perusona Surī', %s)$$, pg_temp.id('game'), pg_temp.tid('game', 'ja')), NULL);
SELECT pg_temp.t('Arabic latinized the same way',       format($$INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (%s, 'ar-Latn', 'full', 'Birsuna 3', %s)$$, pg_temp.id('game'), pg_temp.tid('game', 'ar')), NULL);
SELECT pg_temp.t('another entity''s title',  format($$INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (%s, 'ja-Latn', 'alternative', 'Ishida Akira', %s)$$, pg_temp.id('game'), pg_temp.tid('person', 'ja')), 'title_latinizes_fk');
SELECT pg_temp.t('not in Latin script',      format($$INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (%s, 'ja', 'alternative', 'ぺるそな', %s)$$, pg_temp.id('game'), pg_temp.tid('game', 'ja')), 'title_latinized_latin_ck');
SELECT pg_temp.t('a latinized title is never native', format($$INSERT INTO core.title (entity_id, lang, title_type, text, native, latinizes_id) VALUES (%s, 'en-Latn', 'full', 'Persona Three', true, %s)$$, pg_temp.id('game'), pg_temp.tid('game', 'ja')), 'title_latinized_not_native_ck');
SELECT pg_temp.t('not itself',               format($$UPDATE core.title SET latinizes_id = id WHERE id = %s$$, pg_temp.tid('game', 'ja-Latn')), 'title_latinizes_self_ck');
SELECT pg_temp.t('the source keeps its latinized title', format($$DELETE FROM core.title WHERE id = %s$$, pg_temp.tid('game', 'ar')), 'title_latinizes_fk');
