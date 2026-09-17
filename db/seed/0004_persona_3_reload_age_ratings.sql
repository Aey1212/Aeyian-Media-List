-- ============================================================================
-- Persona 3 Reload's age ratings: ESRB Mature 17+, PEGI 16, CERO C.
--
-- Written from memory: check them. They sit on the game itself, because they are
-- the same on all five platforms; a release gets its own rating only when it
-- differs. Persona 3 (2006) stays unrated here: its rating is not known for sure.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id)
SELECT g.entity_id, 'game', r.id
  FROM core.resolve('/04/0001/002') g
 CROSS JOIN (VALUES ('PEGI', '16'), ('ESRB', 'Mature 17+'), ('CERO', 'C')) AS want (system_name, rating_name)
  JOIN core.entity s ON s.kind = 'age_rating_system'
                    AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = s.id AND t.lang = 'en' AND t.text = want.system_name)
  JOIN core.entity r ON r.kind = 'age_rating' AND r.parent_id = s.id
                    AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = r.id AND t.lang = 'en' AND t.text = want.rating_name);

DO $$
BEGIN
  IF (SELECT count(*) FROM core.entity_age_rating a JOIN core.resolve('/04/0001/002') g ON g.entity_id = a.entity_id) <> 3 THEN
    RAISE EXCEPTION 'seed: expected Persona 3 Reload to get 3 age ratings';
  END IF;
END $$;

COMMIT;
