-- ============================================================================
-- Age rating systems PEGI, ESRB and CERO with their ratings.
--
-- Real data, not placeholders. Names are the ones printed on the icons in Aey's
-- pack (added by 0003_age_rating_icons.py). PEGI has no official "rating
-- pending": that icon is Aey's own, so the rating is here too.
--
-- Minimum ages: printed on the icons for PEGI, Everyone 10+, Mature 17+,
-- Adults Only 18+ and CERO B/C/D/Z. "All ages" ratings (Everyone, CERO A) are 0.
-- Early Childhood 3 and Teen 13 are the ESRB's own ages, written from memory:
-- check them. Pending ratings have none.
--
-- A rating's title does not repeat its system's name (the rating sits under its
-- system): pages show them together, "PEGI 16", "ESRB Mature 17+", "CERO C".
--
-- PEGI's regions are left empty: its country list still needs checking.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.entity WHERE kind = 'age_rating_system') THEN
    RAISE EXCEPTION 'seed: age rating systems already exist';
  END IF;
END $$;

DO $$
DECLARE
  s record; r record; v_system bigint; v_rating bigint;
BEGIN
  FOR s IN
    SELECT * FROM (VALUES
      (1, 'PEGI', '{}'::core.country_code[]),
      (2, 'ESRB', '{US,CA}'),
      (3, 'CERO', '{JP}')
    ) AS v (ord, name, regions)
    ORDER BY ord
  LOOP
    v_system := core.create_entity('age_rating_system');
    INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v_system, 'en', 'full', s.name, true);
    UPDATE world.age_rating_system SET regions = s.regions WHERE entity_id = v_system;

    FOR r IN
      SELECT * FROM (VALUES
        ('PEGI', 1, '3',               NULL,     3),
        ('PEGI', 2, '7',               NULL,     7),
        ('PEGI', 3, '12',              NULL,     12),
        ('PEGI', 4, '16',              NULL,     16),
        ('PEGI', 5, '18',              NULL,     18),
        ('PEGI', 6, 'Rating Pending',  NULL,     NULL),
        ('ESRB', 1, 'Early Childhood', NULL,     3),
        ('ESRB', 2, 'Everyone',        NULL,     0),
        ('ESRB', 3, 'Everyone 10+',    NULL,     10),
        ('ESRB', 4, 'Teen',            NULL,     13),
        ('ESRB', 5, 'Mature 17+',      NULL,     17),
        ('ESRB', 6, 'Adults Only 18+', NULL,     18),
        ('ESRB', 7, 'Rating Pending',  NULL,     NULL),
        ('CERO', 1, 'A',               NULL,     0),
        ('CERO', 2, 'B',               NULL,     12),
        ('CERO', 3, 'C',               NULL,     15),
        ('CERO', 4, 'D',               NULL,     17),
        ('CERO', 5, 'Z',               NULL,     18),
        ('CERO', 6, 'Rating Pending',  '審査予定', NULL)
      ) AS v (system_name, ord, en_name, ja_name, min_age)
      WHERE v.system_name = s.name
      ORDER BY ord
    LOOP
      v_rating := core.create_entity('age_rating', NULL, v_system);
      INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v_rating, 'en', 'full', r.en_name, true);
      IF r.ja_name IS NOT NULL THEN
        INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v_rating, 'ja', 'full', r.ja_name, true);
      END IF;
      UPDATE child.age_rating SET min_age = r.min_age WHERE entity_id = v_rating;
    END LOOP;
  END LOOP;

  UPDATE core.entity SET published_at = now()
   WHERE kind IN ('age_rating_system', 'age_rating') AND published_at IS NULL;
END $$;

COMMIT;
