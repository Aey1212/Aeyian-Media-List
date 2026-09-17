-- ============================================================================
-- Toradora!: the franchise and its works (content, approved by Aey 2026/09/17).
--
-- Real launch content, not test data. Loaded with db/dev.sh content locally and
-- the same way on the server. Everything it needs (companies, people, platforms)
-- is created here when missing, found by kind and English name when present.
--
-- Sources: en.wikipedia.org/wiki/Toradora!, ja.wikipedia.org/wiki/とらドラ!,
-- animenewsnetwork.com encyclopedia anime id 10050.
-- Dates are the calendar date in Japan (SCHEMA.md, Data conventions): the TV
-- series aired at 25:30, so 2008-10-02 to 2009-03-26; the manga started in the
-- September 2007 issue of Dengeki Comic Gao!, on sale 2007-07-27.
-- Not here yet: the OVA (an extra episode of the TV series, with the episodes),
-- Toradora SOS! (spin-off), characters and cast, volumes, episodes, themes,
-- genres and tags. Magazines are left out (Outlet is not built).
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

-- find an entity by kind and English name, or create it with its names
CREATE FUNCTION pg_temp.named(p_kind text, p_en text, p_ja text DEFAULT NULL, p_ja_latn text DEFAULT NULL,
                              p_parent bigint DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint; ja bigint;
BEGIN
  SELECT e.id INTO v FROM core.entity e
   WHERE e.kind = p_kind AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.lang = 'en' AND t.text = p_en);
  IF v IS NOT NULL THEN RETURN v; END IF;
  v := core.create_entity(p_kind, NULL, p_parent);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v, 'en', 'full', p_en, true);
  IF p_ja IS NOT NULL THEN
    INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v, 'ja', 'full', p_ja, true) RETURNING id INTO ja;
    IF p_ja_latn IS NOT NULL THEN
      INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (v, 'ja-Latn', 'full', p_ja_latn, ja);
    END IF;
  END IF;
  RETURN v;
END $$;

-- names for a work: English (preferred), Japanese (native), latinized Japanese
CREATE FUNCTION pg_temp.work_titles(p_work bigint, p_en text, p_ja text, p_ja_latn text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE ja bigint;
BEGIN
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (p_work, 'en', 'full', p_en, true);
  INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (p_work, 'ja', 'full', p_ja, true) RETURNING id INTO ja;
  INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (p_work, 'ja-Latn', 'full', p_ja_latn, ja);
  INSERT INTO core.entity_original_language (entity_id, entity_kind, lang)
    SELECT p_work, kind, 'ja' FROM core.entity WHERE id = p_work;
  INSERT INTO core.entity_origin_country (entity_id, entity_kind, country)
    SELECT p_work, kind, 'JP' FROM core.entity WHERE id = p_work;
END $$;

CREATE FUNCTION pg_temp.staff(p_person bigint, p_role text, p_work bigint) RETURNS void LANGUAGE sql AS $$
  INSERT INTO core.staff_credit (person_id, role, target_id, target_kind)
  SELECT p_person, p_role, p_work, kind FROM core.entity WHERE id = p_work
$$;

CREATE FUNCTION pg_temp.company(p_company bigint, p_role text, p_work bigint) RETURNS void LANGUAGE sql AS $$
  INSERT INTO core.company_credit (company_id, role, target_id, target_kind)
  SELECT p_company, p_role, p_work, kind FROM core.entity WHERE id = p_work
$$;

DO $$
DECLARE
  v_franchise bigint; v_ln bigint; v_ln_spin bigint; v_manga bigint; v_anime bigint; v_game bigint; rel bigint; ja bigint;
  takemiya bigint; yasu bigint; zekkyo bigint; nagai bigint; okada bigint; tanaka bigint;
  hashimoto bigint; aketagawa bigint; shibata bigint;
  amw bigint; dengeki_bunko bigint; seven_seas bigint; jcstaff bigint; tv_tokyo bigint;
  nis bigint; discotek bigint; namco bigint; guyzware bigint;
  playstation bigint; psp bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM core.entity e JOIN core.title t ON t.entity_id = e.id
              WHERE e.kind = 'franchise' AND t.lang = 'en' AND t.text = 'Toradora!') THEN
    RAISE EXCEPTION 'content: Toradora! is already loaded';
  END IF;

  -- the franchise
  v_franchise := core.create_entity('franchise');
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v_franchise, 'en', 'full', 'Toradora!', true);
  INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v_franchise, 'ja', 'full', 'とらドラ！', true) RETURNING id INTO ja;
  INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (v_franchise, 'ja-Latn', 'full', 'Toradora!', ja);

  -- people
  takemiya  := pg_temp.named('person', 'Yuyuko Takemiya',    '竹宮ゆゆこ', 'Takemiya Yuyuko');
  yasu      := pg_temp.named('person', 'Yasu',               'ヤス',       'Yasu');
  zekkyo    := pg_temp.named('person', 'Zekkyō',             '絶叫',       'Zekkyō');
  nagai     := pg_temp.named('person', 'Tatsuyuki Nagai',    '長井龍雪',   'Nagai Tatsuyuki');
  okada     := pg_temp.named('person', 'Mari Okada',         '岡田麿里',   'Okada Mari');
  tanaka    := pg_temp.named('person', 'Masayoshi Tanaka',   '田中将賀',   'Tanaka Masayoshi');
  hashimoto := pg_temp.named('person', 'Yukari Hashimoto',   '橋本由香利', 'Hashimoto Yukari');
  aketagawa := pg_temp.named('person', 'Jin Aketagawa',      '明田川仁',   'Aketagawa Jin');
  shibata   := pg_temp.named('person', 'Chikako Shibata',    '柴田千佳子', 'Shibata Chikako');

  -- companies
  amw           := pg_temp.named('company', 'ASCII Media Works', 'アスキー・メディアワークス', 'Asukī Media Wākusu');
  dengeki_bunko := pg_temp.named('company', 'Dengeki Bunko',     '電撃文庫',                   'Dengeki Bunko');
  seven_seas    := pg_temp.named('company', 'Seven Seas Entertainment');
  jcstaff       := pg_temp.named('company', 'J.C.Staff');
  tv_tokyo      := pg_temp.named('company', 'TV Tokyo',          'テレビ東京',                 'Terebi Tōkyō');
  nis           := pg_temp.named('company', 'NIS America');
  discotek      := pg_temp.named('company', 'Discotek Media');
  namco         := pg_temp.named('company', 'Namco Bandai Games', 'バンダイナムコゲームス',    'Bandai Namuko Gēmusu');
  guyzware      := pg_temp.named('company', 'Guyzware');

  -- platform
  playstation := pg_temp.named('platform_family', 'PlayStation');
  psp         := pg_temp.named('platform', 'PlayStation Portable', p_parent => playstation);

  -- 1. Light novel
  v_ln := core.create_entity('light_novel', v_franchise);
  PERFORM pg_temp.work_titles(v_ln, 'Toradora!', 'とらドラ！', 'Toradora!');
  UPDATE media.work SET status = 'finished', start_date = '2006-03-10', end_date = '2009-03-10', source_type = 'original' WHERE entity_id = v_ln;
  UPDATE media.light_novel SET volume_count = 10 WHERE entity_id = v_ln;
  PERFORM pg_temp.staff(takemiya, 'writer', v_ln);
  PERFORM pg_temp.staff(yasu, 'illustrator', v_ln);
  PERFORM pg_temp.company(amw, 'publisher', v_ln);
  PERFORM pg_temp.company(dengeki_bunko, 'imprint', v_ln);
  PERFORM pg_temp.company(seven_seas, 'localization_publisher', v_ln);

  -- 2. Light novel spin-off
  v_ln_spin := core.create_entity('light_novel', v_franchise);
  PERFORM pg_temp.work_titles(v_ln_spin, 'Toradora Spin-off!', 'とらドラ・スピンオフ！', 'Toradora Supin''ofu!');
  UPDATE media.work SET status = 'finished', start_date = '2007-05-10', end_date = '2010-04-10', source_type = 'light_novel' WHERE entity_id = v_ln_spin;
  UPDATE media.light_novel SET volume_count = 3 WHERE entity_id = v_ln_spin;
  PERFORM pg_temp.staff(takemiya, 'writer', v_ln_spin);
  PERFORM pg_temp.staff(yasu, 'illustrator', v_ln_spin);
  PERFORM pg_temp.company(amw, 'publisher', v_ln_spin);
  PERFORM pg_temp.company(dengeki_bunko, 'imprint', v_ln_spin);
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  VALUES (v_ln_spin, 'light_novel', 'spin_off_of', v_ln, 'light_novel');

  -- 3. Manga
  v_manga := core.create_entity('manga', v_franchise);
  PERFORM pg_temp.work_titles(v_manga, 'Toradora!', 'とらドラ！', 'Toradora!');
  UPDATE media.work SET status = 'publishing', start_date = '2007-07-27', source_type = 'light_novel' WHERE entity_id = v_manga;
  UPDATE media.manga SET volume_count = 12 WHERE entity_id = v_manga;   -- as of 2026-04-27
  PERFORM pg_temp.staff(takemiya, 'original_creator', v_manga);
  PERFORM pg_temp.staff(yasu, 'original_character_designer', v_manga);
  PERFORM pg_temp.staff(zekkyo, 'illustrator', v_manga);
  PERFORM pg_temp.company(amw, 'publisher', v_manga);
  PERFORM pg_temp.company(seven_seas, 'localization_publisher', v_manga);
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  VALUES (v_manga, 'manga', 'adaptation_of', v_ln, 'light_novel');

  -- 4. TV anime
  v_anime := core.create_entity('anime', v_franchise);
  PERFORM pg_temp.work_titles(v_anime, 'Toradora!', 'とらドラ！', 'Toradora!');
  UPDATE media.work SET status = 'finished', start_date = '2008-10-02', end_date = '2009-03-26', source_type = 'light_novel' WHERE entity_id = v_anime;
  UPDATE media.anime SET format = 'tv', episode_count = 25, typical_runtime_s = 24 * 60 WHERE entity_id = v_anime;
  PERFORM pg_temp.staff(takemiya, 'original_creator', v_anime);
  PERFORM pg_temp.staff(yasu, 'original_character_designer', v_anime);
  PERFORM pg_temp.staff(nagai, 'director', v_anime);
  PERFORM pg_temp.staff(okada, 'series_composition', v_anime);
  PERFORM pg_temp.staff(hashimoto, 'composer', v_anime);
  PERFORM pg_temp.staff(tanaka, 'character_designer', v_anime);
  PERFORM pg_temp.staff(tanaka, 'chief_animation_director', v_anime);
  PERFORM pg_temp.staff(shibata, 'art_director', v_anime);
  PERFORM pg_temp.staff(aketagawa, 'sound_director', v_anime);
  PERFORM pg_temp.company(jcstaff, 'animation_studio', v_anime);
  PERFORM pg_temp.company(tv_tokyo, 'original_network', v_anime);
  PERFORM pg_temp.company(nis, 'licensor', v_anime);
  PERFORM pg_temp.company(discotek, 'licensor', v_anime);
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  VALUES (v_anime, 'anime', 'adaptation_of', v_ln, 'light_novel');

  -- 6. PSP game
  v_game := core.create_entity('game', v_franchise);
  PERFORM pg_temp.work_titles(v_game, 'Toradora Portable!', 'とらドラ・ポータブル！', 'Toradora Pōtaburu!');
  UPDATE media.work SET status = 'released', start_date = '2009-04-30', source_type = 'light_novel' WHERE entity_id = v_game;
  PERFORM pg_temp.company(namco, 'publisher', v_game);
  PERFORM pg_temp.company(guyzware, 'developer', v_game);
  rel := core.create_entity('release', NULL, v_game);
  INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (rel, 'en', 'full', 'PlayStation Portable', true);
  UPDATE child.release SET released_on = '2009-04-30', region = 'JP', platform_id = psp WHERE entity_id = rel;
  INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  VALUES (v_game, 'game', 'adaptation_of', v_ln, 'light_novel');

  -- everything new with a name goes public
  UPDATE core.entity e SET published_at = now()
   WHERE e.published_at IS NULL AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id);
END $$;

COMMIT;
