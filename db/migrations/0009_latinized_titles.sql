-- ============================================================================
-- Migration 0009 — "romanization" is called "latinization".
--
-- Aey (2026/09/17): a title spelled out in Latin script works the same way for
-- Japanese (romaji), Arabic and every other non-Latin script, so the name is not
-- tied to Japanese. Only names change: the rules from layer 3 stay as they are.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

ALTER TABLE core.title RENAME COLUMN romanizes_id TO latinizes_id;
ALTER TABLE core.title RENAME CONSTRAINT title_romanizes_fk               TO title_latinizes_fk;
ALTER TABLE core.title RENAME CONSTRAINT title_romanizes_self_ck          TO title_latinizes_self_ck;
ALTER TABLE core.title RENAME CONSTRAINT title_romanization_latin_ck      TO title_latinized_latin_ck;
ALTER TABLE core.title RENAME CONSTRAINT title_romanization_not_native_ck TO title_latinized_not_native_ck;

COMMENT ON COLUMN core.title.latinizes_id IS
  'A latinized title (ja-Latn romaji, ar-Latn ...) points to the title it spells out in Latin script.';

COMMIT;
