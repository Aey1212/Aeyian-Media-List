-- ============================================================================
-- Sample data for local development: Persona 3 Reload and what it connects to.
--
-- Facts: titles, dates, platforms, developer and publisher, the remake link, the
-- DLC, the composer and the franchise link. The six characters and their Japanese
-- and English voice actors were written from memory: check them.
--
-- PLACEHOLDERS, not real: Aey's General Score, subratings, playtime and status,
-- and the Metacritic and HowLongToBeat numbers. The Take text comes from Aey's
-- tier-list note.
--
-- Needs an empty database: db/dev.sh reset --yes && db/dev.sh up && db/dev.sh seed
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.entity) THEN
    RAISE EXCEPTION 'seed: the database already has entities; run db/dev.sh reset --yes && db/dev.sh up first';
  END IF;
END $$;

CREATE FUNCTION pg_temp.title(p_entity bigint, p_lang text, p_text text,
                              p_native boolean DEFAULT false, p_preferred boolean DEFAULT false,
                              p_romanizes bigint DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO core.title (entity_id, lang, title_type, text, native, preferred, romanizes_id)
  VALUES (p_entity, p_lang, 'full', p_text, p_native, p_preferred, p_romanizes)
  RETURNING id
$$;

DO $$
DECLARE
  persona bigint; smt bigint;
  atlus bigint; sega bigint; meguro bigint;
  fam_ps bigint; fam_xbox bigint; fam_pc bigint;
  ps2 bigint; ps4 bigint; ps5 bigint; xone bigint; xsx bigint; win bigint;
  g_rpg bigint; g_jrpg bigint; g_social bigint; t_turn bigint; t_calendar bigint;
  p3 bigint; p3r bigint; v_dlc bigint; rel bigint; ja bigint;   -- v_dlc: "dlc" would clash with child.dlc
  plat bigint;
  c record; v_character bigint; v_appearance bigint; v_actor bigint;
BEGIN
  -- franchises (Persona first, so it is /21/0001)
  persona := core.create_entity('franchise');
  PERFORM pg_temp.title(persona, 'en', 'Persona', p_preferred => true);
  PERFORM pg_temp.title(persona, 'ja', 'ペルソナ', p_native => true);
  smt := core.create_entity('franchise');
  PERFORM pg_temp.title(smt, 'en', 'Shin Megami Tensei', p_preferred => true);
  PERFORM pg_temp.title(smt, 'ja', '真・女神転生', p_native => true);
  INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (persona, 'spin_off_of', smt);

  -- companies and people
  atlus := core.create_entity('company');
  PERFORM pg_temp.title(atlus, 'en', 'Atlus', p_preferred => true);
  PERFORM pg_temp.title(atlus, 'ja', 'アトラス', p_native => true);
  sega := core.create_entity('company');
  PERFORM pg_temp.title(sega, 'en', 'Sega', p_preferred => true);
  PERFORM pg_temp.title(sega, 'ja', 'セガ', p_native => true);
  meguro := core.create_entity('person');
  PERFORM pg_temp.title(meguro, 'en', 'Shoji Meguro', p_preferred => true);
  ja := pg_temp.title(meguro, 'ja', '目黒将司', p_native => true);
  PERFORM pg_temp.title(meguro, 'ja-Latn', 'Meguro Shōji', p_romanizes => ja);

  -- platforms
  fam_ps := core.create_entity('platform_family');   PERFORM pg_temp.title(fam_ps, 'en', 'PlayStation', p_preferred => true);
  fam_xbox := core.create_entity('platform_family'); PERFORM pg_temp.title(fam_xbox, 'en', 'Xbox', p_preferred => true);
  fam_pc := core.create_entity('platform_family');   PERFORM pg_temp.title(fam_pc, 'en', 'PC', p_preferred => true);
  ps2 := core.create_entity('platform', NULL, fam_ps);    PERFORM pg_temp.title(ps2, 'en', 'PlayStation 2', p_preferred => true);
  ps4 := core.create_entity('platform', NULL, fam_ps);    PERFORM pg_temp.title(ps4, 'en', 'PlayStation 4', p_preferred => true);
  ps5 := core.create_entity('platform', NULL, fam_ps);    PERFORM pg_temp.title(ps5, 'en', 'PlayStation 5', p_preferred => true);
  xone := core.create_entity('platform', NULL, fam_xbox); PERFORM pg_temp.title(xone, 'en', 'Xbox One', p_preferred => true);
  xsx := core.create_entity('platform', NULL, fam_xbox);  PERFORM pg_temp.title(xsx, 'en', 'Xbox Series X|S', p_preferred => true);
  win := core.create_entity('platform', NULL, fam_pc);    PERFORM pg_temp.title(win, 'en', 'Windows', p_preferred => true);

  -- genres and tags
  g_rpg := core.create_entity('genre');    PERFORM pg_temp.title(g_rpg, 'en', 'Role-Playing', p_preferred => true);
  g_jrpg := core.create_entity('genre');   PERFORM pg_temp.title(g_jrpg, 'en', 'JRPG', p_preferred => true);
  g_social := core.create_entity('genre'); PERFORM pg_temp.title(g_social, 'en', 'Social Simulation', p_preferred => true);
  INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (g_jrpg, g_rpg);
  t_turn := core.create_entity('tag');     PERFORM pg_temp.title(t_turn, 'en', 'Turn-Based Combat', p_preferred => true);
  t_calendar := core.create_entity('tag'); PERFORM pg_temp.title(t_calendar, 'en', 'Calendar System', p_preferred => true);

  -- Persona 3 (2006)
  p3 := core.create_entity('game', persona);
  PERFORM pg_temp.title(p3, 'en', 'Persona 3', p_preferred => true);
  ja := pg_temp.title(p3, 'ja', 'ペルソナ3', p_native => true);
  PERFORM pg_temp.title(p3, 'ja-Latn', 'Perusona Surī', p_romanizes => ja);
  UPDATE media.work SET status = 'released', start_date = '2006-07-13', source_type = 'original' WHERE entity_id = p3;
  UPDATE media.game SET local_players_min = 1, local_players_max = 1, online_players_min = 0, online_players_max = 0 WHERE entity_id = p3;
  INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (p3, 'game', g_jrpg), (p3, 'game', g_social);
  INSERT INTO core.company_credit (company_id, role, target_id, target_kind) VALUES (atlus, 'developer', p3, 'game'), (atlus, 'publisher', p3, 'game');
  INSERT INTO core.staff_credit (person_id, role, target_id, target_kind) VALUES (meguro, 'composer', p3, 'game');
  rel := core.create_entity('release', NULL, p3);
  PERFORM pg_temp.title(rel, 'en', 'PlayStation 2', p_preferred => true);
  UPDATE child.release SET released_on = '2006-07-13', region = 'JP', platform_id = ps2 WHERE entity_id = rel;

  -- Persona 3 Reload
  p3r := core.create_entity('game', persona);
  PERFORM pg_temp.title(p3r, 'en', 'Persona 3 Reload', p_preferred => true);
  ja := pg_temp.title(p3r, 'ja', 'ペルソナ3 リロード', p_native => true);
  PERFORM pg_temp.title(p3r, 'ja-Latn', 'Perusona Surī Rirōdo', p_romanizes => ja);
  UPDATE media.work SET status = 'released', start_date = '2024-02-02', source_type = 'game' WHERE entity_id = p3r;
  UPDATE media.game SET local_players_min = 1, local_players_max = 1, online_players_min = 0, online_players_max = 0 WHERE entity_id = p3r;
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind) VALUES (p3r, 'game', 'remake_of', p3, 'game');
  INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (p3r, 'game', g_jrpg), (p3r, 'game', g_social);
  INSERT INTO core.entity_tag (entity_id, entity_kind, tag_id) VALUES (p3r, 'game', t_turn), (p3r, 'game', t_calendar);
  INSERT INTO core.company_credit (company_id, role, target_id, target_kind) VALUES (atlus, 'developer', p3r, 'game'), (sega, 'publisher', p3r, 'game');
  INSERT INTO core.staff_credit (person_id, role, target_id, target_kind) VALUES (meguro, 'composer', p3r, 'game');
  INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (p3r, 'game', 'ja');
  INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (p3r, 'game', 'JP');
  FOREACH plat IN ARRAY ARRAY[ps4, ps5, xone, xsx, win] LOOP
    rel := core.create_entity('release', NULL, p3r);
    PERFORM pg_temp.title(rel, 'en', (SELECT t.text FROM core.title t WHERE t.entity_id = plat AND t.preferred), p_preferred => true);
    UPDATE child.release SET released_on = '2024-02-02', platform_id = plat WHERE entity_id = rel;
  END LOOP;
  INSERT INTO ext.link (entity_id, entity_kind, url, caption) VALUES (p3r, 'game', 'https://store.steampowered.com/app/2161700/', core.label_en('Steam'));

  v_dlc := core.create_entity('dlc', NULL, p3r);
  PERFORM pg_temp.title(v_dlc, 'en', 'Episode Aigis -The Answer-', p_preferred => true);
  UPDATE child.dlc SET category = 'story', released_on = '2024-09-10' WHERE entity_id = v_dlc;

  -- characters in Persona 3 Reload, with Japanese and English voices
  FOR c IN
    SELECT * FROM (VALUES
      (0, 'Makoto Yuki',    '結城理',     'protagonist', 'Akira Ishida',      '石田彰',     'Aleks Le'),
      (1, 'Yukari Takeba',  '岳羽ゆかり', 'main',        'Megumi Toyoguchi',  '豊口めぐみ', 'Alix Wilton Regan'),
      (2, 'Junpei Iori',    '伊織順平',   'main',        'Kosuke Toriumi',    '鳥海浩輔',   'Zeno Robinson'),
      (3, 'Akihiko Sanada', '真田明彦',   'main',        'Hikaru Midorikawa', '緑川光',     'Alejandro Saab'),
      (4, 'Mitsuru Kirijo', '桐条美鶴',   'main',        'Rie Tanaka',        '田中理恵',   'Allegra Clark'),
      (5, 'Aigis',          'アイギス',   'main',        'Maaya Sakamoto',    '坂本真綾',   'Dawn M. Bennett')
    ) AS v (ord, en_name, ja_name, role, ja_voice, ja_voice_native, en_voice)
  LOOP
    v_character := core.create_entity('character');
    PERFORM pg_temp.title(v_character, 'en', c.en_name, p_preferred => true);
    PERFORM pg_temp.title(v_character, 'ja', c.ja_name, p_native => true);
    INSERT INTO core.appearance (character_id, target_id, target_kind, sort_order)
    VALUES (v_character, p3r, 'game', c.ord) RETURNING id INTO v_appearance;
    INSERT INTO core.appearance_role_link (appearance_id, role) VALUES (v_appearance, c.role);

    v_actor := core.create_entity('person');
    PERFORM pg_temp.title(v_actor, 'en', c.ja_voice, p_preferred => true);
    PERFORM pg_temp.title(v_actor, 'ja', c.ja_voice_native, p_native => true);
    INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang)
    VALUES (v_actor, v_character, p3r, 'game', 'voice', 'ja');

    v_actor := core.create_entity('person');
    PERFORM pg_temp.title(v_actor, 'en', c.en_voice, p_preferred => true);
    INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang)
    VALUES (v_actor, v_character, p3r, 'game', 'voice', 'en');
  END LOOP;

  -- PLACEHOLDERS: Aey's own data
  INSERT INTO aey.subrating_category (code, labels, sort_order) VALUES ('tone', core.label_en('Tone'), 90) ON CONFLICT (code) DO NOTHING;
  INSERT INTO aey.score (entity_id, entity_kind, general) VALUES (p3r, 'game', 32);
  INSERT INTO aey.subrating (entity_id, entity_kind, category, value) VALUES
    (p3r, 'game', 'gameplay', 40), (p3r, 'game', 'music', 35), (p3r, 'game', 'tone', -15);
  INSERT INTO aey.take (entity_id, entity_kind, lang, body) VALUES
    (p3r, 'game', 'en', 'Tries to be Persona 5, and that doesn''t fit Persona 3''s tone. The FeMC route is gone.');
  INSERT INTO aey.progress (entity_id, entity_kind, status, time_spent_s) VALUES (p3r, 'game', 'completed', 94 * 3600);

  -- PLACEHOLDERS: outside numbers
  INSERT INTO ext.rating (entity_id, entity_kind, source, metric, score) VALUES
    (p3r, 'game', 'metacritic', 'metascore', 88),
    (p3r, 'game', 'howlongtobeat', 'main_story', 60);

  -- everything with a title goes public
  UPDATE core.entity e SET published_at = now()
   WHERE EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id);
END $$;

COMMIT;
