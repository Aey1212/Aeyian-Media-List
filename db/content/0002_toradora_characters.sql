-- ============================================================================
-- Toradora!: characters, cast, and the SOS! shorts (content, approved by Aey
-- 2026/09/17). Needs 0001_toradora_works.sql.
--
-- Characters appear in the light novel, the manga and the TV anime. Aey: Ryuji
-- and Taiga are both protagonists; bit parts are "Background".
--
-- Cast, each with a source:
--   TV anime, Japanese   ja.wikipedia.org/wiki/とらドラ! (登場人物)
--   TV anime, English    en.wikipedia.org/wiki/Toradora! (NIS America dub, 2014)
--   PSP game, Japanese   ja.wikipedia.org/wiki/とらドラ・ポータブル! (same 15 actors)
--   SOS! shorts, Japanese  myanimelist.net/anime/6127 (7 of them)
-- The spin-off light novels get no cast or appearances yet (not checked).
--
-- Toradora SOS!: 4 shorts of about 5 minutes, J.C.Staff, released with the
-- even-numbered DVD volumes, never on TV. Dates 2009-02-03 to 2009-08-26 from
-- MyAnimeList; a fan wiki says the first came on 2009-02-25 — CHECK.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

-- find an entity by kind and English name, or create it with its names
CREATE FUNCTION pg_temp.named(p_kind text, p_en text, p_ja text DEFAULT NULL, p_ja_latn text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint; ja bigint;
BEGIN
  SELECT e.id INTO v FROM core.entity e
   WHERE e.kind = p_kind AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.lang = 'en' AND t.text = p_en);
  IF v IS NOT NULL THEN RETURN v; END IF;
  v := core.create_entity(p_kind);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v, 'en', 'full', p_en, true);
  IF p_ja IS NOT NULL THEN
    INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v, 'ja', 'full', p_ja, true) RETURNING id INTO ja;
    IF p_ja_latn IS NOT NULL THEN
      INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (v, 'ja-Latn', 'full', p_ja_latn, ja);
    END IF;
  END IF;
  RETURN v;
END $$;

CREATE FUNCTION pg_temp.work(p_kind text, p_en text) RETURNS bigint LANGUAGE sql AS $$
  SELECT e.id FROM core.entity e
   WHERE e.kind = p_kind AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.lang = 'en' AND t.text = p_en)
$$;

CREATE FUNCTION pg_temp.appears(p_character bigint, p_work bigint, p_role text, p_order smallint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO core.appearance (character_id, target_id, target_kind, sort_order)
  SELECT p_character, p_work, kind, p_order FROM core.entity WHERE id = p_work
  ON CONFLICT ON CONSTRAINT appearance_uq DO NOTHING
  RETURNING id INTO v;
  IF v IS NOT NULL THEN
    INSERT INTO core.appearance_role_link (appearance_id, role) VALUES (v, p_role);
  END IF;
END $$;

CREATE FUNCTION pg_temp.voices(p_person bigint, p_character bigint, p_work bigint, p_lang text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang)
  SELECT p_person, p_character, p_work, kind, 'voice', p_lang FROM core.entity WHERE id = p_work
$$;

DO $$
DECLARE
  v_ln bigint; v_manga bigint; v_anime bigint; v_game bigint; v_sos bigint; v_franchise bigint;
  jcstaff bigint; c record; v_character bigint; ja_voice bigint; en_voice bigint; n smallint := 0;
BEGIN
  v_ln       := pg_temp.work('light_novel', 'Toradora!');
  v_manga    := pg_temp.work('manga', 'Toradora!');
  v_anime    := pg_temp.work('anime', 'Toradora!');
  v_game     := pg_temp.work('game', 'Toradora Portable!');
  IF v_ln IS NULL OR v_manga IS NULL OR v_anime IS NULL OR v_game IS NULL THEN
    RAISE EXCEPTION 'content: needs 0001_toradora_works.sql first';
  END IF;
  IF pg_temp.work('anime', 'Toradora SOS!') IS NOT NULL THEN
    RAISE EXCEPTION 'content: Toradora! characters are already loaded';
  END IF;

  -- Toradora SOS!: shorts that came with the DVDs, a spin-off of the TV series
  SELECT franchise_id INTO v_franchise FROM core.entity WHERE id = v_anime;
  v_sos := core.create_entity('anime', v_franchise);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v_sos, 'en', 'full', 'Toradora SOS!', true);
  INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v_sos, 'ja', 'full', 'とらドラ! SOS! 食いしん坊万々歳', true);
  INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id)
  SELECT v_sos, 'ja-Latn', 'full', 'Toradora! SOS! Kuishinbō Banbanzai', id FROM core.title WHERE entity_id = v_sos AND lang = 'ja';
  UPDATE media.work SET status = 'finished', start_date = '2009-02-03', end_date = '2009-08-26', source_type = 'light_novel' WHERE entity_id = v_sos;
  UPDATE media.anime SET format = 'special', episode_count = 4, typical_runtime_s = 5 * 60 WHERE entity_id = v_sos;
  INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (v_sos, 'anime', 'ja');
  INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (v_sos, 'anime', 'JP');
  jcstaff := pg_temp.named('company', 'J.C.Staff');
  INSERT INTO core.company_credit (company_id, role, target_id, target_kind) VALUES (jcstaff, 'animation_studio', v_sos, 'anime');
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  VALUES (v_sos, 'anime', 'spin_off_of', v_anime, 'anime');

  -- characters, their roles, and who voiced them
  FOR c IN
    SELECT * FROM (VALUES
      ('Ryuji Takasu',    '高須竜児',   'Takasu Ryūji',    'protagonist', 'Junji Majima',      '間島淳司',   'Majima Junji',    'Erik Scott Kimerer',      true,  true),
      ('Taiga Aisaka',    '逢坂大河',   'Aisaka Taiga',    'protagonist', 'Rie Kugimiya',      '釘宮理恵',   'Kugimiya Rie',    'Cassandra Lee Morris',    true,  true),
      ('Minori Kushieda', '櫛枝実乃梨', 'Kushieda Minori', 'main',        'Yui Horie',         '堀江由衣',   'Horie Yui',       'Christine Marie Cabanos', true,  true),
      ('Ami Kawashima',   '川嶋亜美',   'Kawashima Ami',   'main',        'Eri Kitamura',      '喜多村英梨', 'Kitamura Eri',    'Erika Harlacher',         true,  true),
      ('Yusaku Kitamura', '北村祐作',   'Kitamura Yūsaku', 'main',        'Hirofumi Nojima',   '野島裕史',   'Nojima Hirofumi', 'Johnny Yong Bosch',       true,  true),
      ('Yasuko Takasu',   '高須泰子',   'Takasu Yasuko',   'supporting',  'Sayaka Ōhara',      '大原さやか', 'Ōhara Sayaka',    'Karen Strassman',         true,  false),
      ('Yuri Koigakubo',  '恋ヶ窪ゆり', 'Koigakubo Yuri',  'supporting',  'Rie Tanaka',        '田中理恵',   'Tanaka Rie',      'Carrie Keranen',          true,  true),
      ('Sumire Kanō',     '狩野すみれ', 'Kanō Sumire',     'supporting',  'Yūko Kaida',        '甲斐田裕子', 'Kaida Yūko',      'Wendee Lee',              true,  false),
      ('Maya Kihara',     '木原麻耶',   'Kihara Maya',     'supporting',  'Ai Nonaka',         '野中藍',     'Nonaka Ai',       'Mela Lee',                true,  false),
      ('Nanako Kashii',   '香椎奈々子', 'Kashii Nanako',   'supporting',  'Momoko Ishikawa',   '石川桃子',   'Ishikawa Momoko', 'Karen Strassman',         true,  false),
      ('Hisamitsu Noto',  '能登久光',   'Noto Hisamitsu',  'supporting',  'Kazuyuki Okitsu',   '興津和幸',   'Okitsu Kazuyuki', 'Max Mittelman',           true,  false),
      ('Kōji Haruta',     '春田浩次',   'Haruta Kōji',     'supporting',  'Hiroyuki Yoshino',  '吉野裕行',   'Yoshino Hiroyuki','Brian Beacock',           true,  false),
      ('Kōta Tomiie',     '富家幸太',   'Tomiie Kōta',     'supporting',  'Nobuhiko Okamoto',  '岡本信彦',   'Okamoto Nobuhiko','Ben Giroux',              true,  false),
      ('Sakura Kanō',     '狩野さくら', 'Kanō Sakura',     'supporting',  'Kana Asumi',        '阿澄佳奈',   'Asumi Kana',      'Faye Mata',               true,  false),
      ('Inko-chan',       'インコちゃん', 'Inko-chan',     'supporting',  'Saori Gotō',        '後藤沙緒里', 'Gotō Saori',      'Wendee Lee',              true,  true),
      ('Kuroma',          '黒間',       'Kuroma',          'background',  'Nobuaki Kanemitsu', '金光宣明',   'Kanemitsu Nobuaki', NULL,                    false, false)
    ) AS v (en_name, ja_name, ja_latn, role, ja_voice_en, ja_voice_ja, ja_voice_latn, en_voice, in_game, in_sos)
  LOOP
    v_character := pg_temp.named('character', c.en_name, c.ja_name, c.ja_latn);
    ja_voice := pg_temp.named('person', c.ja_voice_en, c.ja_voice_ja, c.ja_voice_latn);

    -- the novel, the manga and the anime have them all; Kuroma only shows in the anime
    IF c.role <> 'background' THEN
      PERFORM pg_temp.appears(v_character, v_ln, c.role, n);
      PERFORM pg_temp.appears(v_character, v_manga, c.role, n);
    END IF;
    PERFORM pg_temp.appears(v_character, v_anime, c.role, n);
    PERFORM pg_temp.voices(ja_voice, v_character, v_anime, 'ja');
    IF c.en_voice IS NOT NULL THEN
      en_voice := pg_temp.named('person', c.en_voice);
      PERFORM pg_temp.voices(en_voice, v_character, v_anime, 'en');
    END IF;
    IF c.in_game THEN
      PERFORM pg_temp.appears(v_character, v_game, c.role, n);
      PERFORM pg_temp.voices(ja_voice, v_character, v_game, 'ja');
    END IF;
    IF c.in_sos THEN
      PERFORM pg_temp.appears(v_character, v_sos, c.role, n);
      PERFORM pg_temp.voices(ja_voice, v_character, v_sos, 'ja');
    END IF;
    n := n + 1;
  END LOOP;

  -- everything new with a name goes public
  UPDATE core.entity e SET published_at = now()
   WHERE e.published_at IS NULL AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id);
END $$;

COMMIT;
