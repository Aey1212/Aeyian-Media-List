-- ============================================================================
-- Tests for migration 0008 — display names for kinds.
-- Run with db/test.sh (applies migrations 0001..0008 to a fresh database).
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

\echo '--- kind labels'
SELECT pg_temp.eq('every kind has a label', (SELECT count(*) FILTER (WHERE labels IS NULL) || ' missing of ' || count(*) FROM core.entity_kind), '0 missing of 23');
SELECT pg_temp.eq('media labels', (SELECT string_agg(labels -> 'en' ->> 'text', ', ' ORDER BY code) FROM core.entity_kind WHERE family = 'media'),
  'Anime, Manga, Light Novel, Game, Series, Movie');
SELECT pg_temp.eq('child labels', (SELECT string_agg(labels -> 'en' ->> 'text', ', ' ORDER BY code) FROM core.entity_kind WHERE family = 'child'),
  'Season, Episode, Volume, DLC, Release, Cut / Edition, Soundtrack, Platform, Age Rating');
SELECT pg_temp.eq('world labels', (SELECT string_agg(labels -> 'en' ->> 'text', ', ' ORDER BY code) FROM core.entity_kind WHERE family = 'world'),
  'Franchise, Character, Person, Company, Platform Family, Genre, Tag, Age Rating System');
SELECT pg_temp.t('a new kind needs a label', $$INSERT INTO core.entity_kind (name, code, family, scope, seq_width) VALUES ('webtoon', '07', 'media', 'franchise', 3)$$, 'column "labels"');
SELECT pg_temp.t('...and gets one',          $$INSERT INTO core.entity_kind (name, code, family, scope, seq_width, labels) VALUES ('webtoon', '07', 'media', 'franchise', 3, core.label_en('Webtoon'))$$, NULL);
SELECT pg_temp.t('labels are validated',     $$UPDATE core.entity_kind SET labels = '{}' WHERE name = 'webtoon'$$, 'at least one language is required');
SELECT pg_temp.t('a native Japanese label',  $$UPDATE core.entity_kind SET labels = '{"en": {"text": "Anime", "native": false}, "ja": {"text": "アニメ", "native": true}}' WHERE name = 'anime'$$, NULL);
