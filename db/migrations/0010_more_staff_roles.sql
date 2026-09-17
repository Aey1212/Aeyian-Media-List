-- ============================================================================
-- Migration 0010 — staff roles an anime and a light novel need (Toradora!).
--
-- Roles are rows (PLANNING.md: defaults plus custom roles). Sort order places
-- them among the existing ones, which pages use to list roles.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

INSERT INTO core.staff_role (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('original_creator',            'Original Creator',             2),
  ('illustrator',                 'Illustrator',                  4),
  ('series_composition',          'Series Composition',          15),
  ('original_character_designer', 'Original Character Designer', 38),
  ('chief_animation_director',    'Chief Animation Director',    42),
  ('art_director',                'Art Director',                44),
  ('sound_director',              'Sound Director',              46)
) AS v (code, label, sort);

COMMIT;
