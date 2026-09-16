-- ============================================================================
-- Tests for migration 0005 — child entities and platforms.
-- Run with db/test.sh (applies migrations 0001..0005 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- Each section creates its own fixtures.
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

CREATE TEMP TABLE ids (name text PRIMARY KEY, id bigint NOT NULL);
CREATE FUNCTION pg_temp.id(n text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM ids WHERE name = n $$;

CREATE FUNCTION pg_temp.codes(sch text, tbl text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SELECT string_agg(code, '','' ORDER BY sort_order) FROM %I.%I', sch, tbl) INTO r;
  RETURN r;
END $$;

CREATE FUNCTION pg_temp.cols(sch text, tbl text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
   WHERE table_schema = sch AND table_name = tbl $$;

-- ----------------------------------------------------------------------------
-- Parents used across the sections
-- ----------------------------------------------------------------------------
INSERT INTO ids VALUES ('anime', core.create_entity('anime')), ('series', core.create_entity('series')),
  ('manga', core.create_entity('manga')), ('ln', core.create_entity('light_novel')),
  ('game', core.create_entity('game')), ('movie', core.create_entity('movie')),
  ('family', core.create_entity('platform_family')), ('pc_family', core.create_entity('platform_family')),
  ('rating_system', core.create_entity('age_rating_system'));

\echo '--- every child kind can be created as a bare row'
-- core.create_entity inserts the type row empty, so no child type table may demand
-- a value at creation time. (A "number or display name" check on seasons once made
-- seasons impossible to create.)
DO $x$
DECLARE s1 bigint;
BEGIN
  s1 := core.create_entity('season', NULL, pg_temp.id('series'));
  INSERT INTO ids VALUES ('s1', s1);
  INSERT INTO ids VALUES
    ('cour2',    core.create_entity('season',     NULL, pg_temp.id('anime'))),
    ('ep1',      core.create_entity('episode',    NULL, s1)),
    ('ep12_5',   core.create_entity('episode',    NULL, s1)),
    ('anime_ep', core.create_entity('episode',    NULL, pg_temp.id('anime'))),
    ('v1',       core.create_entity('volume',     NULL, pg_temp.id('manga'))),
    ('v6_5',     core.create_entity('volume',     NULL, pg_temp.id('manga'))),
    ('ln_v1',    core.create_entity('volume',     NULL, pg_temp.id('ln'))),
    ('dlc',      core.create_entity('dlc',        NULL, pg_temp.id('game'))),
    ('grel',     core.create_entity('release',    NULL, pg_temp.id('game'))),
    ('mrel',     core.create_entity('release',    NULL, pg_temp.id('movie'))),
    ('cut',      core.create_entity('cut',        NULL, pg_temp.id('movie'))),
    ('ost',      core.create_entity('soundtrack', NULL, pg_temp.id('anime'))),
    ('ps5',      core.create_entity('platform',   NULL, pg_temp.id('family'))),
    ('rating',   core.create_entity('age_rating', NULL, pg_temp.id('rating_system')));
END $x$;
SELECT pg_temp.eq('all 9 child kinds created bare',
  (SELECT count(DISTINCT e.kind)::text FROM core.entity e JOIN ids i ON i.id = e.id WHERE e.family = 'child'), '9');

\echo '--- platforms'
INSERT INTO ids VALUES ('ps2', core.create_entity('platform', NULL, pg_temp.id('family'))),
                       ('windows', core.create_entity('platform', NULL, pg_temp.id('pc_family')));
SELECT pg_temp.eq('kinds',      (SELECT count(*) FROM core.entity_kind)::text, '23');
SELECT pg_temp.eq('placements', (SELECT count(*) FROM core.entity_kind_parent)::text, '25');
SELECT pg_temp.eq('new kinds',  (SELECT string_agg(code || ' ' || name || ' ' || family || ' ' || scope || ' w' || seq_width, '; ' ORDER BY code)
                                   FROM core.entity_kind WHERE name IN ('platform_family', 'platform')),
  '18 platform child parent w2; 26 platform_family world global w2');
SELECT pg_temp.eq('kinds without a type table',
  (SELECT string_agg(k.family || '.' || k.name, ',') FROM core.entity_kind k
     LEFT JOIN information_schema.tables t ON t.table_schema = k.family AND t.table_name = k.name WHERE t.table_name IS NULL), NULL);
SELECT pg_temp.eq('family address',        core.address(pg_temp.id('family')),  '/26/01');
SELECT pg_temp.eq('a platform under it',   core.address(pg_temp.id('ps5')),     '/26/01/18/01');
SELECT pg_temp.eq('the next one',          core.address(pg_temp.id('ps2')),     '/26/01/18/02');
SELECT pg_temp.eq('another family',        core.address(pg_temp.id('windows')), '/26/02/18/01');
SELECT pg_temp.eq('resolve a platform',    (SELECT entity_id FROM core.resolve('/26/01/18/02'))::text, pg_temp.id('ps2')::text);
SELECT pg_temp.t('a platform under a game',     format($$SELECT core.create_entity('platform', NULL, %s)$$, pg_temp.id('game')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('a platform with no family',   $$SELECT core.create_entity('platform')$$, 'entity_parent_scope_ck');
SELECT pg_temp.t('platform dates',              format($$UPDATE child.platform SET released_on = '2000-03-04', discontinued = '2013' WHERE entity_id = %s$$, pg_temp.id('ps2')), NULL);
SELECT pg_temp.t('discontinued before release', format($$UPDATE child.platform SET released_on = '2000-03-04', discontinued = '1999' WHERE entity_id = %s$$, pg_temp.id('ps2')), 'platform_dates_order_ck');
SELECT pg_temp.eq('no work rows for platforms', (SELECT count(*) FROM media.work w JOIN core.entity e ON e.id = w.entity_id WHERE e.kind IN ('platform', 'platform_family'))::text, '0');

\echo '--- option lists'
SELECT pg_temp.eq('DLC categories',    pg_temp.codes('media', 'dlc_category'), 'expansion,story,character,cosmetic,season_pass,other');
SELECT pg_temp.eq('release types',     pg_temp.codes('media', 'release_type'), 'theatrical,limited_theatrical,premiere,festival,television,streaming,home_video,retail,store');
SELECT pg_temp.eq('distribution',      pg_temp.codes('media', 'distribution'), 'physical,digital');
SELECT pg_temp.eq('cut types',         pg_temp.codes('media', 'cut_type'), 'theatrical,directors,extended,unrated,restored');
SELECT pg_temp.eq('theme types',       pg_temp.codes('media', 'theme_type'), 'opening,ending,insert,theme');
SELECT pg_temp.eq('staff roles now',   pg_temp.codes('core', 'staff_role'), 'director,writer,composer,character_designer,performer');
SELECT pg_temp.eq('company roles now', pg_temp.codes('core', 'company_role'), 'animation_studio,developer,publisher,production_company,distributor,licensor,broadcaster,original_network,localization_publisher,imprint,label');
SELECT pg_temp.t('a new DLC category is a row',  $$INSERT INTO media.dlc_category (code, labels, sort_order) VALUES ('weapon_pack', core.label_en('Weapon Pack'), 35)$$, NULL);
SELECT pg_temp.t('category code must be lowercase', $$INSERT INTO media.dlc_category (code, labels) VALUES ('Weapon', core.label_en('Weapon'))$$, 'dlc_category_code_ck');
SELECT pg_temp.t('option labels are validated',  $$INSERT INTO media.release_type (code, labels) VALUES ('bundle', '{}')$$, 'at least one language is required');

\echo '--- seasons'
SELECT pg_temp.t('season 1 with dates',        format($$UPDATE child.season SET number = 1, started_on = '2019-04-06', ended_on = '2019-06-29' WHERE entity_id = %s$$, pg_temp.id('s1')), NULL);
SELECT pg_temp.t('Cour 2: number and name',    format($$UPDATE child.season SET number = 2, display_name = 'Cour 2' WHERE entity_id = %s$$, pg_temp.id('cour2')), NULL);
INSERT INTO ids VALUES ('specials', core.create_entity('season', NULL, pg_temp.id('series')));
SELECT pg_temp.t('Specials: name, no number',  format($$UPDATE child.season SET display_name = 'Specials' WHERE entity_id = %s$$, pg_temp.id('specials')), NULL);
SELECT pg_temp.t('a season with neither is allowed', format($$UPDATE child.season SET number = NULL, display_name = NULL WHERE entity_id = %s$$, pg_temp.id('specials')), NULL);
SELECT pg_temp.t('blank display name',         format($$UPDATE child.season SET display_name = '  ' WHERE entity_id = %s$$, pg_temp.id('specials')), 'season_display_name_ck');
SELECT pg_temp.t('negative season number',     format($$UPDATE child.season SET number = -1 WHERE entity_id = %s$$, pg_temp.id('s1')), 'season_number_ck');
SELECT pg_temp.t('ends before it starts',      format($$UPDATE child.season SET started_on = '2019-04-06', ended_on = '2019-01' WHERE entity_id = %s$$, pg_temp.id('s1')), 'season_dates_order_ck');
SELECT pg_temp.t('season 0 is allowed',        format($$UPDATE child.season SET number = 0 WHERE entity_id = %s$$, pg_temp.id('specials')), NULL);
SELECT pg_temp.eq('season columns', pg_temp.cols('child', 'season'), 'entity_id,kind,number,display_name,started_on,ended_on');

\echo '--- episodes'
SELECT pg_temp.t('episode 1', format($$UPDATE child.episode SET number_in_season = 1, number_overall = 1, aired_on = '2019-04-06', runtime_s = 1440, source_coverage = 'adapts chapters 1-8' WHERE entity_id = %s$$, pg_temp.id('ep1')), NULL);
SELECT pg_temp.t('episode 12.5 special', format($$UPDATE child.episode SET number_in_season = 12.5, number_overall = 12.5, runtime_s = 1400 WHERE entity_id = %s$$, pg_temp.id('ep12_5')), NULL);
SELECT pg_temp.eq('...stored as 12.5', (SELECT number_in_season::text FROM child.episode WHERE entity_id = pg_temp.id('ep12_5')), '12.50');
SELECT pg_temp.t('an episode directly under an anime', format($$UPDATE child.episode SET number_overall = 3, aired_on = '2008-10-16' WHERE entity_id = %s$$, pg_temp.id('anime_ep')), NULL);
SELECT pg_temp.t('negative episode number', format($$UPDATE child.episode SET number_in_season = -1 WHERE entity_id = %s$$, pg_temp.id('ep1')), 'episode_number_in_season_ck');
SELECT pg_temp.t('zero runtime',            format($$UPDATE child.episode SET runtime_s = 0 WHERE entity_id = %s$$, pg_temp.id('ep1')), 'seconds_ck');
SELECT pg_temp.t('impossible air date',     format($$UPDATE child.episode SET aired_on = '2019-02-30' WHERE entity_id = %s$$, pg_temp.id('ep1')), 'is not a real calendar date');
SELECT pg_temp.eq('episode 1 reads back', (SELECT number_in_season || '/' || number_overall || ' ' || aired_on || ' ' || runtime_s || 's ' || source_coverage FROM child.episode WHERE entity_id = pg_temp.id('ep1')), '1.00/1.00 2019-04-06 1440s adapts chapters 1-8');
SELECT pg_temp.eq('episode columns', pg_temp.cols('child', 'episode'), 'entity_id,kind,number_in_season,number_overall,aired_on,runtime_s,source_coverage');

\echo '--- volumes and ISBNs'
SELECT pg_temp.t('volume 1: pages, chapters, date', format($$UPDATE child.volume SET number = 1, released_on = '2007-03-10', page_count = 200, chapter_from = 1, chapter_to = 8, contents = 'chapters 1-8 and a bonus story' WHERE entity_id = %s$$, pg_temp.id('v1')), NULL);
SELECT pg_temp.t('volume 6.5',             format($$UPDATE child.volume SET number = 6.5, page_count = 120 WHERE entity_id = %s$$, pg_temp.id('v6_5')), NULL);
SELECT pg_temp.eq('...stored as 6.5',      (SELECT number::text FROM child.volume WHERE entity_id = pg_temp.id('v6_5')), '6.50');
SELECT pg_temp.t('chapters 9 to 3',        format($$UPDATE child.volume SET chapter_from = 9, chapter_to = 3 WHERE entity_id = %s$$, pg_temp.id('ln_v1')), 'volume_chapter_range_ck');
SELECT pg_temp.t('zero pages',             format($$UPDATE child.volume SET page_count = 0 WHERE entity_id = %s$$, pg_temp.id('v1')), 'volume_page_count_ck');
SELECT pg_temp.t('negative volume number', format($$UPDATE child.volume SET number = -1 WHERE entity_id = %s$$, pg_temp.id('v1')), 'volume_number_ck');
SELECT pg_temp.t('ISBN-13',                format($$INSERT INTO child.volume_isbn (volume_id, isbn) VALUES (%s, '9784048671316')$$, pg_temp.id('v1')), NULL);
SELECT pg_temp.t('ISBN-10 as well',        format($$INSERT INTO child.volume_isbn (volume_id, isbn, note) VALUES (%s, '4048671316', 'first printing')$$, pg_temp.id('v1')), NULL);
SELECT pg_temp.t('ISBN-10 ending in X',    format($$INSERT INTO child.volume_isbn (volume_id, isbn) VALUES (%s, '404867131X')$$, pg_temp.id('v6_5')), NULL);
SELECT pg_temp.t('the same ISBN twice',    format($$INSERT INTO child.volume_isbn (volume_id, isbn) VALUES (%s, '9784048671316')$$, pg_temp.id('v1')), 'volume_isbn_pkey');
SELECT pg_temp.t('an ISBN with hyphens',   format($$INSERT INTO child.volume_isbn (volume_id, isbn) VALUES (%s, '978-4-04-867131-6')$$, pg_temp.id('v6_5')), 'volume_isbn_format_ck');
SELECT pg_temp.t('a too-short ISBN',       format($$INSERT INTO child.volume_isbn (volume_id, isbn) VALUES (%s, '12345')$$, pg_temp.id('v6_5')), 'volume_isbn_format_ck');
SELECT pg_temp.eq('volume 1 ISBNs',        (SELECT string_agg(isbn, ',' ORDER BY isbn) FROM child.volume_isbn WHERE volume_id = pg_temp.id('v1')), '4048671316,9784048671316');
SELECT pg_temp.eq('volume columns', pg_temp.cols('child', 'volume'), 'entity_id,kind,number,released_on,page_count,chapter_from,chapter_to,contents');

\echo '--- DLC and cuts'
SELECT pg_temp.t('story DLC with a date',  format($$UPDATE child.dlc SET category = 'story', released_on = '2024-09-10' WHERE entity_id = %s$$, pg_temp.id('dlc')), NULL);
SELECT pg_temp.t('unknown DLC category',   format($$UPDATE child.dlc SET category = 'skins' WHERE entity_id = %s$$, pg_temp.id('dlc')), 'dlc_category_fk');
SELECT pg_temp.t('director''s cut, 3 hours, changes', format($$UPDATE child.cut SET cut_type = 'directors', runtime_s = 10800, changes = '47 minutes of added footage' WHERE entity_id = %s$$, pg_temp.id('cut')), NULL);
SELECT pg_temp.t('unknown cut type',       format($$UPDATE child.cut SET cut_type = 'fan_edit' WHERE entity_id = %s$$, pg_temp.id('cut')), 'cut_cut_type_fk');
SELECT pg_temp.t('zero runtime on a cut',  format($$UPDATE child.cut SET runtime_s = 0 WHERE entity_id = %s$$, pg_temp.id('cut')), 'seconds_ck');
SELECT pg_temp.t('renaming a category',    $$UPDATE media.dlc_category SET code = 'story_dlc' WHERE code = 'story'$$, NULL);
SELECT pg_temp.eq('...the DLC follows',    (SELECT category FROM child.dlc WHERE entity_id = pg_temp.id('dlc')), 'story_dlc');
SELECT pg_temp.eq('dlc columns', pg_temp.cols('child', 'dlc'), 'entity_id,kind,category,released_on');
SELECT pg_temp.eq('cut columns', pg_temp.cols('child', 'cut'), 'entity_id,kind,cut_type,runtime_s,changes');

\echo '--- releases and their languages'
SELECT pg_temp.t('game release: store, JP, a platform, digital', format($$UPDATE child.release SET release_type = 'store', region = 'JP', released_on = '2024-02-02', platform_id = %s, distribution = 'digital' WHERE entity_id = %s$$, pg_temp.id('ps5'), pg_temp.id('grel')), NULL);
SELECT pg_temp.t('movie release: theatrical, TR, no platform', format($$UPDATE child.release SET release_type = 'theatrical', region = 'TR', released_on = '2024-06' WHERE entity_id = %s$$, pg_temp.id('mrel')), NULL);
SELECT pg_temp.t('unknown release type',   format($$UPDATE child.release SET release_type = 'bluray' WHERE entity_id = %s$$, pg_temp.id('mrel')), 'release_release_type_fk');
SELECT pg_temp.t('lowercase region',       format($$UPDATE child.release SET region = 'jp' WHERE entity_id = %s$$, pg_temp.id('grel')), 'country_code_ck');
SELECT pg_temp.t('unknown distribution',   format($$UPDATE child.release SET distribution = 'cartridge' WHERE entity_id = %s$$, pg_temp.id('grel')), 'release_distribution_fk');
SELECT pg_temp.t('an anime as the platform', format($$UPDATE child.release SET platform_id = %s WHERE entity_id = %s$$, pg_temp.id('anime'), pg_temp.id('mrel')), 'release_platform_fk');
SELECT pg_temp.t('delete a platform a release uses', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ps5')), 'release_platform_fk');
SELECT pg_temp.t('languages ja, en, tr',   format($$INSERT INTO child.release_language (release_id, lang, sort_order) VALUES (%1$s, 'ja', 0), (%1$s, 'en', 1)$$, pg_temp.id('grel')), NULL);
SELECT pg_temp.t('...and Turkish subtitles', format($$INSERT INTO child.release_language (release_id, lang, note, sort_order) VALUES (%s, 'tr', 'subtitles only', 2)$$, pg_temp.id('grel')), NULL);
SELECT pg_temp.t('the same language twice', format($$INSERT INTO child.release_language (release_id, lang) VALUES (%s, 'ja')$$, pg_temp.id('grel')), 'release_language_pkey');
SELECT pg_temp.t('a language name, not a tag', format($$INSERT INTO child.release_language (release_id, lang) VALUES (%s, 'Japanese')$$, pg_temp.id('grel')), 'lang_tag_ck');
SELECT pg_temp.eq('languages in order',    (SELECT string_agg(lang, ',' ORDER BY sort_order) FROM child.release_language WHERE release_id = pg_temp.id('grel')), 'ja,en,tr');
SELECT pg_temp.eq('release columns', pg_temp.cols('child', 'release'), 'entity_id,kind,release_type,region,released_on,platform_id,platform_kind,distribution');

\echo '--- soundtracks, tracks and themes'
SELECT pg_temp.t('soundtrack date and runtime', format($$UPDATE child.soundtrack SET released_on = '2009-01-28', runtime_s = 3720 WHERE entity_id = %s$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.t('track 1 with a Japanese title', format($$INSERT INTO child.soundtrack_track (soundtrack_id, disc_no, track_no, titles, runtime_s) VALUES (%s, 1, 1, '{"ja": {"text": "プレパレード", "native": true}, "ja-Latn": {"text": "Pre-Parade", "native": false}}', 268)$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.t('track 2',                  format($$INSERT INTO child.soundtrack_track (soundtrack_id, disc_no, track_no, titles) VALUES (%s, 1, 2, core.label_en('Vanilla Salt'))$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.t('a track with no disc number', format($$INSERT INTO child.soundtrack_track (soundtrack_id, track_no, titles) VALUES (%s, 1, core.label_en('Bonus Track'))$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.t('the same disc and track again', format($$INSERT INTO child.soundtrack_track (soundtrack_id, disc_no, track_no, titles) VALUES (%s, 1, 1, core.label_en('Duplicate'))$$, pg_temp.id('ost')), 'soundtrack_track_uq');
SELECT pg_temp.t('no disc number, same track number again', format($$INSERT INTO child.soundtrack_track (soundtrack_id, track_no, titles) VALUES (%s, 1, core.label_en('Another Bonus'))$$, pg_temp.id('ost')), 'soundtrack_track_uq');
SELECT pg_temp.t('track 0',                  format($$INSERT INTO child.soundtrack_track (soundtrack_id, track_no, titles) VALUES (%s, 0, core.label_en('Zero'))$$, pg_temp.id('ost')), 'soundtrack_track_no_ck');
SELECT pg_temp.t('a track with empty titles', format($$INSERT INTO child.soundtrack_track (soundtrack_id, track_no, titles) VALUES (%s, 9, '{}')$$, pg_temp.id('ost')), 'at least one language is required');
SELECT pg_temp.eq('the native track title',  (SELECT titles -> 'ja' ->> 'text' FROM child.soundtrack_track WHERE soundtrack_id = pg_temp.id('ost') AND disc_no = 1 AND track_no = 1), 'プレパレード');
SELECT pg_temp.t('track 1 is the episode''s opening', format($$INSERT INTO child.episode_theme (episode_id, track_id, theme_type) SELECT %s, t.id, 'opening' FROM child.soundtrack_track t WHERE t.soundtrack_id = %s AND t.disc_no = 1 AND t.track_no = 1$$, pg_temp.id('ep1'), pg_temp.id('ost')), NULL);
SELECT pg_temp.t('track 2 is the ending',    format($$INSERT INTO child.episode_theme (episode_id, track_id, theme_type) SELECT %s, t.id, 'ending' FROM child.soundtrack_track t WHERE t.soundtrack_id = %s AND t.disc_no = 1 AND t.track_no = 2$$, pg_temp.id('ep1'), pg_temp.id('ost')), NULL);
SELECT pg_temp.t('the same theme twice',     format($$INSERT INTO child.episode_theme (episode_id, track_id, theme_type) SELECT %s, t.id, 'opening' FROM child.soundtrack_track t WHERE t.soundtrack_id = %s AND t.disc_no = 1 AND t.track_no = 1$$, pg_temp.id('ep1'), pg_temp.id('ost')), 'episode_theme_pkey');
SELECT pg_temp.t('an unknown theme type',    format($$INSERT INTO child.episode_theme (episode_id, track_id, theme_type) SELECT %s, t.id, 'jingle' FROM child.soundtrack_track t WHERE t.soundtrack_id = %s AND t.track_no = 1 AND t.disc_no IS NULL$$, pg_temp.id('ep1'), pg_temp.id('ost')), 'episode_theme_type_fk');
SELECT pg_temp.t('a theme on the anime, not an episode', format($$INSERT INTO child.episode_theme (episode_id, track_id, theme_type) SELECT %s, t.id, 'opening' FROM child.soundtrack_track t WHERE t.soundtrack_id = %s AND t.track_no = 1 AND t.disc_no IS NULL$$, pg_temp.id('anime'), pg_temp.id('ost')), 'episode_theme_episode_fk');
SELECT pg_temp.eq('themes of the episode', (SELECT string_agg(th.theme_type, ',' ORDER BY th.theme_type) FROM child.episode_theme th WHERE th.episode_id = pg_temp.id('ep1')), 'ending,opening');
SELECT pg_temp.eq('soundtrack columns', pg_temp.cols('child', 'soundtrack'), 'entity_id,kind,released_on,runtime_s');

\echo '--- deletes'
SELECT pg_temp.t('delete volume 1',        format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('v1')), NULL);
SELECT pg_temp.eq('its ISBNs went too',    (SELECT count(*) FROM child.volume_isbn WHERE volume_id = pg_temp.id('v1'))::text, '0');
SELECT pg_temp.t('delete the game release', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('grel')), NULL);
SELECT pg_temp.eq('its languages went too', (SELECT count(*) FROM child.release_language WHERE release_id = pg_temp.id('grel'))::text, '0');
SELECT pg_temp.t('now the platform can go', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ps5')), NULL);
SELECT pg_temp.t('delete the soundtrack',   format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.eq('its tracks and the episode''s themes went',
  ((SELECT count(*) FROM child.soundtrack_track WHERE soundtrack_id = pg_temp.id('ost'))
 + (SELECT count(*) FROM child.episode_theme WHERE episode_id = pg_temp.id('ep1')))::text, '0');

\echo '--- earlier layers still hold'
SELECT pg_temp.eq('every media entity has its work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('anime'))))::text, pg_temp.id('anime')::text);
