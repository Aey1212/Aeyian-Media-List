-- ============================================================================
-- Test data: one character across several games, in different roles, with
-- different voice actors. Made so Makoto Yuki's page (/22/0001) has more than
-- one appearance.
--
-- Persona 3 (2006): the six characters from 0001 in the same roles. Japanese
-- voices are the same as in Reload; the English voices are the 2007 dub, written
-- from memory: check them. Also gives Persona 3 its original language and country.
--
-- Persona 5 Royal: NOT REAL. Makoto Yuki as an optional boss, voiced by Akira
-- Ishida and Aleks Le, only to test a third game with a different role and an
-- actor who appears in two games. The game itself (title, date, platform,
-- developer) is real.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

CREATE FUNCTION pg_temp.by_title(p_kind text, p_text text) RETURNS bigint LANGUAGE sql AS $$
  SELECT e.id FROM core.entity e
   WHERE e.kind = p_kind
     AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.lang = 'en' AND t.text = p_text)
$$;

CREATE FUNCTION pg_temp.person(p_en text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  v := pg_temp.by_title('person', p_en);
  IF v IS NULL THEN
    v := core.create_entity('person');
    INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v, 'en', 'full', p_en, true);
  END IF;
  RETURN v;
END $$;

DO $$
DECLARE
  persona bigint := (SELECT entity_id FROM core.resolve('/21/0001'));
  p3 bigint := (SELECT entity_id FROM core.resolve('/04/0001/001'));
  atlus bigint := pg_temp.by_title('company', 'Atlus');
  ps4 bigint := pg_temp.by_title('platform', 'PlayStation 4');
  p5r bigint; rel bigint; ja bigint;
  c record; v_character bigint; v_appearance bigint;
BEGIN
  IF p3 IS NULL OR atlus IS NULL OR ps4 IS NULL THEN
    RAISE EXCEPTION 'seed: needs 0001_persona_3_reload.sql first';
  END IF;
  IF EXISTS (SELECT 1 FROM core.appearance WHERE target_id = p3) OR pg_temp.by_title('game', 'Persona 5 Royal') IS NOT NULL THEN
    RAISE EXCEPTION 'seed: this test data is already loaded';
  END IF;

  -- Persona 3 (2006): original language and country, then its characters
  INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (p3, 'game', 'ja');
  INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (p3, 'game', 'JP');

  FOR c IN
    SELECT * FROM (VALUES
      (0, 'Makoto Yuki',    'protagonist', 'Akira Ishida',      'Yuri Lowenthal'),
      (1, 'Yukari Takeba',  'main',        'Megumi Toyoguchi',  'Michelle Ruff'),
      (2, 'Junpei Iori',    'main',        'Kosuke Toriumi',    'Vic Mignogna'),
      (3, 'Akihiko Sanada', 'main',        'Hikaru Midorikawa', 'Liam O''Brien'),
      (4, 'Mitsuru Kirijo', 'main',        'Rie Tanaka',        'Tara Platt'),
      (5, 'Aigis',          'main',        'Maaya Sakamoto',    'Karen Strassman')
    ) AS v (ord, en_name, role, ja_voice, en_voice)
  LOOP
    v_character := pg_temp.by_title('character', c.en_name);
    INSERT INTO core.appearance (character_id, target_id, target_kind, sort_order)
    VALUES (v_character, p3, 'game', c.ord) RETURNING id INTO v_appearance;
    INSERT INTO core.appearance_role_link (appearance_id, role) VALUES (v_appearance, c.role);
    INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang) VALUES
      (pg_temp.person(c.ja_voice), v_character, p3, 'game', 'voice', 'ja'),
      (pg_temp.person(c.en_voice), v_character, p3, 'game', 'voice', 'en');
  END LOOP;

  -- Persona 5 Royal (real game)
  p5r := core.create_entity('game', persona);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (p5r, 'en', 'full', 'Persona 5 Royal', true);
  INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (p5r, 'ja', 'full', 'ペルソナ5 ザ・ロイヤル', true) RETURNING id INTO ja;
  INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (p5r, 'ja-Latn', 'full', 'Perusona Faibu Za Roiyaru', ja);
  UPDATE media.work SET status = 'released', start_date = '2019-10-31', source_type = 'game' WHERE entity_id = p5r;
  INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (p5r, 'game', 'ja');
  INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (p5r, 'game', 'JP');
  INSERT INTO core.company_credit (company_id, role, target_id, target_kind) VALUES (atlus, 'developer', p5r, 'game');
  rel := core.create_entity('release', NULL, p5r);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (rel, 'en', 'full', 'PlayStation 4', true);
  UPDATE child.release SET released_on = '2019-10-31', region = 'JP', platform_id = ps4 WHERE entity_id = rel;

  -- NOT REAL: Makoto Yuki as an optional boss in Persona 5 Royal
  v_character := pg_temp.by_title('character', 'Makoto Yuki');
  INSERT INTO core.appearance (character_id, target_id, target_kind, note)
  VALUES (v_character, p5r, 'game', 'Optional') RETURNING id INTO v_appearance;
  INSERT INTO core.appearance_role_link (appearance_id, role) VALUES (v_appearance, 'boss');
  INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang) VALUES
    (pg_temp.person('Akira Ishida'), v_character, p5r, 'game', 'voice', 'ja'),
    (pg_temp.person('Aleks Le'),     v_character, p5r, 'game', 'voice', 'en');

  -- everything with a title goes public
  UPDATE core.entity e SET published_at = now()
   WHERE e.published_at IS NULL AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id);
END $$;

COMMIT;
