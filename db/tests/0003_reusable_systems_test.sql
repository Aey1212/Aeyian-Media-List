-- ============================================================================
-- Tests for migration 0003 — reusable systems.
-- Run with db/test.sh (applies migrations 0001..0003 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- Each section creates its own fixtures so sections do not depend on each other.
-- Checks on the commit-time title rule use SET CONSTRAINTS ALL IMMEDIATE so the
-- deferred check runs inside the harness.
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

-- first title of an entity with this language and type
CREATE FUNCTION pg_temp.tid(e text, l text, ty text) RETURNS bigint LANGUAGE sql AS $$
  SELECT id FROM core.title WHERE entity_id = pg_temp.id(e) AND lang = l AND title_type = ty ORDER BY id LIMIT 1 $$;

-- fixture names for a set of ids, sorted
CREATE FUNCTION pg_temp.names(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SELECT string_agg(i.name, '','' ORDER BY i.name) FROM ids i WHERE i.id IN (%s)', q) INTO r;
  RETURN r;
END $$;

CREATE FUNCTION pg_temp.codes(tbl text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SELECT string_agg(code, '','' ORDER BY sort_order) FROM core.%I', tbl) INTO r;
  RETURN r;
END $$;

-- 64-character fake hash
CREATE FUNCTION pg_temp.h(c text) RETURNS text LANGUAGE sql AS $$ SELECT repeat(c, 64) $$;

CREATE FUNCTION pg_temp.img(n text, cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO core.image (entity_id, %s) VALUES (%s, %s)', cols, pg_temp.id(n), vals) $$;

\echo '--- option lists'
SELECT pg_temp.eq('title types',       pg_temp.codes('title_type'),       'full,short,alternative');
SELECT pg_temp.eq('text types',        pg_temp.codes('text_type'),        'synopsis,description');
SELECT pg_temp.eq('image types',       pg_temp.codes('image_type'),       'cover,poster,banner,backdrop,box_art,logo,thumbnail,volume_cover,season_poster,portrait,icon');
SELECT pg_temp.eq('staff roles',       pg_temp.codes('staff_role'),       'director,writer,composer,character_designer');
SELECT pg_temp.eq('company roles',     pg_temp.codes('company_role'),     'animation_studio,developer,publisher,production_company,distributor,licensor,broadcaster,original_network,localization_publisher,imprint');
SELECT pg_temp.eq('appearance roles',  pg_temp.codes('appearance_role'),  'protagonist,main,supporting,antagonist,playable,boss,guest');
SELECT pg_temp.eq('performance types', pg_temp.codes('performance_type'), 'voice,live_action,motion_capture');
SELECT pg_temp.t('custom staff role is a row',  $$INSERT INTO core.staff_role (code, labels) VALUES ('storyboard', core.label_en('Storyboard'))$$, NULL);
SELECT pg_temp.t('role code must be lowercase', $$INSERT INTO core.staff_role (code, labels) VALUES ('Storyboard', core.label_en('Storyboard'))$$, 'staff_role_code_ck');
SELECT pg_temp.t('role labels validated',       $$INSERT INTO core.appearance_role (code, labels) VALUES ('cameo', '{}')$$, 'at least one language is required');

\echo '--- new kinds'
INSERT INTO ids VALUES ('k_genre', core.create_entity('genre')), ('k_tag', core.create_entity('tag')),
                       ('k_system', core.create_entity('age_rating_system')), ('k_game', core.create_entity('game'));
INSERT INTO ids VALUES ('k_rating', core.create_entity('age_rating', NULL, pg_temp.id('k_system')));
SELECT pg_temp.eq('kinds',      (SELECT count(*) FROM core.entity_kind)::text, '21');
SELECT pg_temp.eq('placements', (SELECT count(*) FROM core.entity_kind_parent)::text, '24');
SELECT pg_temp.eq('new kinds',  (SELECT string_agg(code || ' ' || name || ' ' || family || ' ' || scope || ' w' || seq_width, '; ' ORDER BY code)
                                   FROM core.entity_kind WHERE name IN ('genre', 'tag', 'age_rating_system', 'age_rating')),
  '19 age_rating child parent w2; 27 genre world global w3; 28 tag world global w3; 29 age_rating_system world global w2');
SELECT pg_temp.eq('kinds without a type table',
  (SELECT string_agg(k.family || '.' || k.name, ',') FROM core.entity_kind k
     LEFT JOIN information_schema.tables t ON t.table_schema = k.family AND t.table_name = k.name WHERE t.table_name IS NULL), NULL);
SELECT pg_temp.eq('genre address',               core.address(pg_temp.id('k_genre')),  '/27/001');
SELECT pg_temp.eq('tag address',                 core.address(pg_temp.id('k_tag')),    '/28/001');
SELECT pg_temp.eq('age rating system address',   core.address(pg_temp.id('k_system')), '/29/01');
SELECT pg_temp.eq('age rating under its system', core.address(pg_temp.id('k_rating')), '/29/01/19/01');
SELECT pg_temp.eq('resolve age rating',          (SELECT entity_id FROM core.resolve('/29/01/19/01'))::text, pg_temp.id('k_rating')::text);
SELECT pg_temp.t('age rating under a game',      format($$SELECT core.create_entity('age_rating', NULL, %s)$$, pg_temp.id('k_game')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('age rating without a system',  $$SELECT core.create_entity('age_rating')$$, 'entity_parent_scope_ck');
SELECT pg_temp.eq('no media.work rows for new kinds',
  (SELECT count(*) FROM media.work w JOIN core.entity e ON e.id = w.entity_id WHERE e.kind IN ('genre', 'tag', 'age_rating_system', 'age_rating'))::text, '0');

\echo '--- titles'
INSERT INTO ids VALUES ('tora', core.create_entity('anime')), ('seiyuu', core.create_entity('person'));
SELECT pg_temp.t('ja full native',            format($$INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (%s, 'ja', 'full', 'とらドラ!', true)$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('romaji full romanizes it',  format($$INSERT INTO core.title (entity_id, lang, title_type, text, romanizes_id) VALUES (%s, 'ja-Latn', 'full', 'Toradora!', %s)$$, pg_temp.id('tora'), pg_temp.tid('tora', 'ja', 'full')), NULL);
SELECT pg_temp.t('en full preferred',         format($$INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (%s, 'en', 'full', 'Toradora!', true)$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('ja short native too',       format($$INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (%s, 'ja', 'short', 'とらドラ', true)$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('two en alternatives',       format($$INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%1$s, 'en', 'alternative', 'Tiger X Dragon'), (%1$s, 'en', 'alternative', 'Toradora')$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('second native full',        format($$INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (%s, 'en', 'full', 'Tiger and Dragon', true)$$, pg_temp.id('tora')), 'title_native_uq');
SELECT pg_temp.t('second preferred en full',  format($$INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (%s, 'en', 'full', 'Tiger and Dragon', true)$$, pg_temp.id('tora')), 'title_preferred_uq');
INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (pg_temp.id('seiyuu'), 'ja', 'full', '堀江 由衣', true);
SELECT pg_temp.t('romanizes another entity''s title', format($$INSERT INTO core.title (entity_id, lang, title_type, text, romanizes_id) VALUES (%s, 'ja-Latn', 'alternative', 'Horie Yui', %s)$$, pg_temp.id('tora'), pg_temp.tid('seiyuu', 'ja', 'full')), 'title_romanizes_fk');
SELECT pg_temp.t('romanizes a different type', format($$INSERT INTO core.title (entity_id, lang, title_type, text, romanizes_id) VALUES (%s, 'ja-Latn', 'short', 'Toradora', %s)$$, pg_temp.id('tora'), pg_temp.tid('tora', 'ja', 'full')), 'title_romanizes_fk');
SELECT pg_temp.t('romanization not in Latin',  format($$INSERT INTO core.title (entity_id, lang, title_type, text, romanizes_id) VALUES (%s, 'ja', 'full', 'トラドラ', %s)$$, pg_temp.id('tora'), pg_temp.tid('tora', 'ja', 'full')), 'title_romanization_latin_ck');
SELECT pg_temp.t('native romanization',        format($$INSERT INTO core.title (entity_id, lang, title_type, text, native, romanizes_id) VALUES (%s, 'ja-Latn', 'full', 'Toradora', true, %s)$$, pg_temp.id('tora'), pg_temp.tid('tora', 'ja', 'full')), 'title_romanization_not_native_ck');
SELECT pg_temp.t('title romanizes itself',     format($$UPDATE core.title SET romanizes_id = id WHERE id = %s$$, pg_temp.tid('tora', 'ja-Latn', 'full')), 'title_romanizes_self_ck');
SELECT pg_temp.t('blank title',                format($$INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'short', '   ')$$, pg_temp.id('tora')), 'title_text_ck');
SELECT pg_temp.t('uppercase language tag',     format($$INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'JA', 'short', 'x')$$, pg_temp.id('tora')), 'lang_tag_ck');
SELECT pg_temp.t('duplicate title',            format($$INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'full', 'Toradora!')$$, pg_temp.id('tora')), 'title_text_uq');
SELECT pg_temp.t('unknown title type',         format($$INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'nickname', 'Tora')$$, pg_temp.id('tora')), 'title_type_fk');
SELECT pg_temp.t('delete a title its romaji points to', format($$DELETE FROM core.title WHERE id = %s$$, pg_temp.tid('tora', 'ja', 'full')), 'title_romanizes_fk');

\echo '--- search'
SELECT pg_temp.eq('Japanese text produces trigrams', (similarity('とらドラ!', 'とらドラ') > 0)::text, 'true');
SELECT pg_temp.eq('typo "toradra" finds it',         (SELECT count(DISTINCT entity_id) FROM core.title WHERE text % 'toradra')::text, '1');
SELECT pg_temp.eq('Japanese substring finds it',     (SELECT count(DISTINCT entity_id) FROM core.title WHERE text ILIKE '%らドラ%')::text, '1');

\echo '--- texts'
SELECT pg_temp.t('en synopsis',        format($$INSERT INTO core.entity_text VALUES (%s, 'synopsis', 'en', 'Ryuji looks like a delinquent.')$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('ja synopsis',        format($$INSERT INTO core.entity_text VALUES (%s, 'synopsis', 'ja', '竜児は不良に見える。')$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('second en synopsis', format($$INSERT INTO core.entity_text VALUES (%s, 'synopsis', 'en', 'Again.')$$, pg_temp.id('tora')), 'entity_text_pkey');
SELECT pg_temp.t('blank body',         format($$INSERT INTO core.entity_text VALUES (%s, 'description', 'en', ' ')$$, pg_temp.id('tora')), 'entity_text_body_ck');
SELECT pg_temp.t('unknown text type',  format($$INSERT INTO core.entity_text VALUES (%s, 'trivia', 'en', 'x')$$, pg_temp.id('tora')), 'entity_text_type_fk');

\echo '--- publishing needs a title'
INSERT INTO ids VALUES ('solo', core.create_entity('movie'));
SELECT pg_temp.t('publish without a title', format($$UPDATE core.entity SET published_at = now() WHERE id = %s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('solo')), 'has no title');
SELECT pg_temp.t('publish with titles',     format($$UPDATE core.entity SET published_at = now() WHERE id = %s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('tora')), NULL);
SELECT pg_temp.t('create, publish, then title in one transaction',
  $$DO $x$ DECLARE i bigint; BEGIN
      i := core.create_entity('game');
      UPDATE core.entity SET published_at = now() WHERE id = i;
      INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (i, 'en', 'full', 'Undertale');
      INSERT INTO ids VALUES ('undertale', i);
    END $x$; SET CONSTRAINTS ALL IMMEDIATE$$, NULL);
SELECT pg_temp.eq('...it is published', (SELECT (published_at IS NOT NULL)::text FROM core.entity WHERE id = pg_temp.id('undertale')), 'true');
SELECT pg_temp.t('remove every title of a published entity', format($$DELETE FROM core.title WHERE entity_id = %s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('tora')), 'has no title');
SELECT pg_temp.t('replace the only title in one transaction', format($$DELETE FROM core.title WHERE entity_id = %1$s; INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%1$s, 'en', 'full', 'UNDERTALE'); SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('undertale')), NULL);
SELECT pg_temp.t('move the only title to another entity', format($$UPDATE core.title SET entity_id = %s WHERE entity_id = %s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('solo'), pg_temp.id('undertale')), 'has no title');
SELECT pg_temp.t('unpublish, then remove titles', format($$UPDATE core.entity SET published_at = NULL WHERE id = %1$s; DELETE FROM core.title WHERE entity_id = %1$s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('undertale')), NULL);
-- committed setup: published anime whose romaji title points at its Japanese title
DO $x$ DECLARE i bigint; ja bigint; BEGIN
  i := core.create_entity('anime');
  INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (i, 'ja', 'full', 'とらドラ!', true) RETURNING id INTO ja;
  INSERT INTO core.title (entity_id, lang, title_type, text, romanizes_id) VALUES (i, 'ja-Latn', 'full', 'Toradora!', ja);
  UPDATE core.entity SET published_at = now() WHERE id = i;
  INSERT INTO ids VALUES ('published_pair', i);
END $x$;
SELECT pg_temp.t('plain delete of a published entity with a romaji title', format($$DELETE FROM core.entity WHERE id = %s; SET CONSTRAINTS ALL IMMEDIATE$$, pg_temp.id('published_pair')), NULL);
SELECT pg_temp.eq('entity and both titles gone',
  (SELECT count(*) FROM core.entity WHERE id = pg_temp.id('published_pair'))::text || '/' || (SELECT count(*) FROM core.title WHERE entity_id = pg_temp.id('published_pair'))::text, '0/0');

\echo '--- genre and tag trees'
INSERT INTO ids VALUES ('action', core.create_entity('genre')), ('rpg', core.create_entity('genre')),
  ('action_rpg', core.create_entity('genre')), ('souls_like', core.create_entity('genre')), ('puzzle', core.create_entity('genre')),
  ('fantasy', core.create_entity('tag')), ('dark_fantasy', core.create_entity('tag')),
  ('ds3', core.create_entity('game')), ('p3r', core.create_entity('game')), ('tetris', core.create_entity('game')),
  ('char', core.create_entity('character'));
INSERT INTO ids VALUES ('ep', core.create_entity('episode', NULL, core.create_entity('anime')));
SELECT pg_temp.eq('genre/tag attach kinds', (SELECT string_agg(system || ':' || cnt, ' ' ORDER BY system) FROM (SELECT system, count(*) cnt FROM core.attach_kind WHERE system IN ('genre', 'tag') GROUP BY system) x), 'genre:6 tag:6');
SELECT pg_temp.t('Action RPG under RPG',         format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('action_rpg'), pg_temp.id('rpg')), NULL);
SELECT pg_temp.t('Action RPG also under Action', format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('action_rpg'), pg_temp.id('action')), NULL);
SELECT pg_temp.t('Souls-like under Action RPG',  format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('souls_like'), pg_temp.id('action_rpg')), NULL);
SELECT pg_temp.t('RPG under Souls-like (loop)',  format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('rpg'), pg_temp.id('souls_like')), 'would create a loop');
SELECT pg_temp.t('loop via update',              format($$UPDATE core.genre_parent SET parent_id = %s WHERE genre_id = %s AND parent_id = %s$$, pg_temp.id('souls_like'), pg_temp.id('action_rpg'), pg_temp.id('rpg')), 'would create a loop');
SELECT pg_temp.t('genre under itself',           format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('rpg'), pg_temp.id('rpg')), 'genre_parent_self_ck');
SELECT pg_temp.t('genre under a tag',            format($$INSERT INTO core.genre_parent (genre_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('rpg'), pg_temp.id('fantasy')), 'genre_parent_parent_fk');
SELECT pg_temp.t('tag under a genre',            format($$INSERT INTO core.tag_parent (tag_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('dark_fantasy'), pg_temp.id('rpg')), 'tag_parent_parent_fk');
SELECT pg_temp.t('Dark Fantasy under Fantasy',   format($$INSERT INTO core.tag_parent (tag_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('dark_fantasy'), pg_temp.id('fantasy')), NULL);
SELECT pg_temp.t('tag loop',                     format($$INSERT INTO core.tag_parent (tag_id, parent_id) VALUES (%s, %s)$$, pg_temp.id('fantasy'), pg_temp.id('dark_fantasy')), 'would create a loop');
SELECT pg_temp.eq('RPG with descendants',        pg_temp.names(format('SELECT core.genre_with_descendants(%s)', pg_temp.id('rpg'))), 'action_rpg,rpg,souls_like');
SELECT pg_temp.eq('Action with descendants',     pg_temp.names(format('SELECT core.genre_with_descendants(%s)', pg_temp.id('action'))), 'action,action_rpg,souls_like');
SELECT pg_temp.eq('leaf with descendants',       pg_temp.names(format('SELECT core.genre_with_descendants(%s)', pg_temp.id('souls_like'))), 'souls_like');
SELECT pg_temp.eq('Fantasy with descendants',    pg_temp.names(format('SELECT core.tag_with_descendants(%s)', pg_temp.id('fantasy'))), 'dark_fantasy,fantasy');

\echo '--- attaching genres and tags'
SELECT pg_temp.t('Souls-like on Dark Souls 3', format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'game', %s)$$, pg_temp.id('ds3'), pg_temp.id('souls_like')), NULL);
SELECT pg_temp.t('RPG on P3R',                 format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'game', %s)$$, pg_temp.id('p3r'), pg_temp.id('rpg')), NULL);
SELECT pg_temp.t('Puzzle on Tetris',           format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'game', %s)$$, pg_temp.id('tetris'), pg_temp.id('puzzle')), NULL);
SELECT pg_temp.t('Dark Fantasy tag on DS3',    format($$INSERT INTO core.entity_tag (entity_id, entity_kind, tag_id) VALUES (%s, 'game', %s)$$, pg_temp.id('ds3'), pg_temp.id('dark_fantasy')), NULL);
SELECT pg_temp.eq('games under RPG incl. descendants',
  pg_temp.names(format('SELECT eg.entity_id FROM core.entity_genre eg WHERE eg.genre_id IN (SELECT core.genre_with_descendants(%s))', pg_temp.id('rpg'))), 'ds3,p3r');
SELECT pg_temp.t('genre on an episode',        format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'episode', %s)$$, pg_temp.id('ep'), pg_temp.id('rpg')), 'entity_genre_allowed_fk');
SELECT pg_temp.t('tag on a character',         format($$INSERT INTO core.entity_tag (entity_id, entity_kind, tag_id) VALUES (%s, 'character', %s)$$, pg_temp.id('char'), pg_temp.id('fantasy')), 'entity_tag_allowed_fk');
SELECT pg_temp.t('kind lies about entity',     format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'anime', %s)$$, pg_temp.id('tetris'), pg_temp.id('rpg')), 'entity_genre_entity_fk');
SELECT pg_temp.t('a tag used as a genre',      format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'game', %s)$$, pg_temp.id('tetris'), pg_temp.id('fantasy')), 'entity_genre_genre_fk');
SELECT pg_temp.t('same genre twice',           format($$INSERT INTO core.entity_genre (entity_id, entity_kind, genre_id) VALUES (%s, 'game', %s)$$, pg_temp.id('ds3'), pg_temp.id('souls_like')), 'entity_genre_pkey');
SELECT pg_temp.t('delete a genre still on a work',  format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('puzzle')), 'entity_genre_genre_fk');
SELECT pg_temp.t('delete a genre that is a parent', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('action')), 'genre_parent_parent_fk');
SELECT pg_temp.t('delete the work',                 format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('tetris')), NULL);
SELECT pg_temp.eq('its genre links went with it',   (SELECT count(*) FROM core.entity_genre WHERE entity_id = pg_temp.id('tetris'))::text, '0');
SELECT pg_temp.t('now the unused genre can go',     format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('puzzle')), NULL);
SELECT pg_temp.t('detach, then delete a leaf with parents', format($$DELETE FROM core.entity_genre WHERE genre_id = %1$s; DELETE FROM core.entity WHERE id = %1$s$$, pg_temp.id('souls_like')), NULL);
SELECT pg_temp.eq('its parent links went with it',  (SELECT count(*) FROM core.genre_parent WHERE genre_id = pg_temp.id('souls_like'))::text, '0');
SELECT pg_temp.eq('Action RPG keeps two parents',   (SELECT count(*) FROM core.genre_parent WHERE genre_id = pg_temp.id('action_rpg'))::text, '2');

\echo '--- age ratings'
INSERT INTO ids VALUES ('pegi', core.create_entity('age_rating_system')), ('esrb', core.create_entity('age_rating_system')),
  ('rated_game', core.create_entity('game')), ('rated_char', core.create_entity('character'));
INSERT INTO ids VALUES ('pegi16', core.create_entity('age_rating', NULL, pg_temp.id('pegi'))),
  ('pegi18', core.create_entity('age_rating', NULL, pg_temp.id('pegi'))),
  ('esrb_m', core.create_entity('age_rating', NULL, pg_temp.id('esrb'))),
  ('rel',       core.create_entity('release', NULL, pg_temp.id('rated_game'))),
  ('rel_clean', core.create_entity('release', NULL, pg_temp.id('rated_game')));
SELECT pg_temp.t('PEGI regions EU, TR, GB', format($$UPDATE world.age_rating_system SET regions = '{EU,TR,GB}' WHERE entity_id = %s$$, pg_temp.id('pegi')), NULL);
SELECT pg_temp.t('lowercase region',        format($$UPDATE world.age_rating_system SET regions = '{us}' WHERE entity_id = %s$$, pg_temp.id('esrb')), 'country_code_ck');
SELECT pg_temp.t('three-letter region',     format($$UPDATE world.age_rating_system SET regions = '{USA}' WHERE entity_id = %s$$, pg_temp.id('esrb')), 'country_code_ck');
SELECT pg_temp.t('PEGI 16 minimum age 16',  format($$UPDATE child.age_rating SET min_age = 16 WHERE entity_id = %s$$, pg_temp.id('pegi16')), NULL);
SELECT pg_temp.t('minimum age 120',         format($$UPDATE child.age_rating SET min_age = 120 WHERE entity_id = %s$$, pg_temp.id('pegi18')), 'age_rating_min_age_ck');
SELECT pg_temp.eq('age rating attach kinds', (SELECT count(*) FROM core.attach_kind WHERE system = 'age_rating')::text, '13');
SELECT pg_temp.t('PEGI 16 on a game, system filled in', format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'game', %s)$$, pg_temp.id('rated_game'), pg_temp.id('pegi16')), NULL);
SELECT pg_temp.eq('...system is PEGI',       (SELECT system_id FROM core.entity_age_rating WHERE entity_id = pg_temp.id('rated_game') AND rating_id = pg_temp.id('pegi16'))::text, pg_temp.id('pegi')::text);
SELECT pg_temp.t('ESRB M on the same game',  format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'game', %s)$$, pg_temp.id('rated_game'), pg_temp.id('esrb_m')), NULL);
SELECT pg_temp.t('second PEGI rating',       format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'game', %s)$$, pg_temp.id('rated_game'), pg_temp.id('pegi18')), 'entity_age_rating_pkey');
SELECT pg_temp.t('PEGI 18 on a release',     format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'release', %s)$$, pg_temp.id('rel'), pg_temp.id('pegi18')), NULL);
SELECT pg_temp.t('rating on a character',    format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'character', %s)$$, pg_temp.id('rated_char'), pg_temp.id('pegi16')), 'entity_age_rating_allowed_fk');
SELECT pg_temp.t('rating given the wrong system', format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id, system_id) VALUES (%s, 'release', %s, %s)$$, pg_temp.id('rel_clean'), pg_temp.id('esrb_m'), pg_temp.id('pegi')), 'entity_age_rating_rating_fk');
SELECT pg_temp.t('a genre used as a rating', format($$INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id, system_id) VALUES (%s, 'release', %s, %s)$$, pg_temp.id('rel_clean'), pg_temp.id('rpg'), pg_temp.id('esrb')), 'entity_age_rating_rating_fk');
SELECT pg_temp.t('swap to another system''s rating without its system', format($$UPDATE core.entity_age_rating SET rating_id = %s WHERE entity_id = %s AND rating_id = %s$$, pg_temp.id('esrb_m'), pg_temp.id('rel'), pg_temp.id('pegi18')), 'entity_age_rating_rating_fk');
SELECT pg_temp.t('change PEGI 16 to PEGI 18', format($$UPDATE core.entity_age_rating SET rating_id = %s WHERE entity_id = %s AND rating_id = %s$$, pg_temp.id('pegi18'), pg_temp.id('rated_game'), pg_temp.id('pegi16')), NULL);
SELECT pg_temp.t('delete a rating in use',   format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('pegi18')), 'entity_age_rating_rating_fk');
SELECT pg_temp.t('delete a system that has ratings', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('esrb')), 'entity_parent_fk');
SELECT pg_temp.t('delete an unused rating',  format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('pegi16')), NULL);
SELECT pg_temp.t('delete the release',       format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('rel')), NULL);
SELECT pg_temp.eq('its rating link went with it', (SELECT count(*) FROM core.entity_age_rating WHERE entity_id = pg_temp.id('rel'))::text, '0');

\echo '--- images'
INSERT INTO ids VALUES ('img_anime', core.create_entity('anime')), ('img_game', core.create_entity('game')),
  ('img_person', core.create_entity('person')), ('img_system', core.create_entity('age_rating_system'));
INSERT INTO ids VALUES ('img_rating', core.create_entity('age_rating', NULL, pg_temp.id('img_system')));
SELECT pg_temp.eq('image formats', (SELECT string_agg(code || '=' || mime_type, ' ' ORDER BY code) FROM core.image_format),
  'avif=image/avif gif=image/gif jpg=image/jpeg png=image/png svg=image/svg+xml webp=image/webp');
SELECT pg_temp.t('primary cover jpg with size', pg_temp.img('img_anime', 'image_type,sha256,format,width,height,byte_size,is_primary', format($$'cover', %L, 'jpg', 460, 650, 88000, true$$, pg_temp.h('a'))), NULL);
SELECT pg_temp.t('second cover, not primary',   pg_temp.img('img_anime', 'image_type,sha256,format,width,height,sort_order', format($$'cover', %L, 'webp', 460, 650, 1$$, pg_temp.h('b'))), NULL);
SELECT pg_temp.t('second primary cover',        pg_temp.img('img_anime', 'image_type,sha256,format,width,height,is_primary', format($$'cover', %L, 'png', 460, 650, true$$, pg_temp.h('c'))), 'image_primary_uq');
SELECT pg_temp.t('primary poster (other type)', pg_temp.img('img_anime', 'image_type,sha256,format,width,height,is_primary', format($$'poster', %L, 'png', 1000, 1500, true$$, pg_temp.h('c'))), NULL);
SELECT pg_temp.t('svg logo without size',       pg_temp.img('img_anime', 'image_type,sha256,format', format($$'logo', %L, 'svg'$$, pg_temp.h('d'))), NULL);
SELECT pg_temp.t('width without height',        pg_temp.img('img_anime', 'image_type,sha256,format,width', format($$'banner', %L, 'jpg', 1200$$, pg_temp.h('e'))), 'image_size_pair_ck');
SELECT pg_temp.t('zero width',                  pg_temp.img('img_anime', 'image_type,sha256,format,width,height', format($$'banner', %L, 'jpg', 0, 300$$, pg_temp.h('e'))), 'image_width_ck');
SELECT pg_temp.t('uppercase hash',              pg_temp.img('img_anime', 'image_type,sha256,format', format($$'banner', %L, 'jpg'$$, pg_temp.h('A'))), 'image_sha256_ck');
SELECT pg_temp.t('unknown format bmp',          pg_temp.img('img_anime', 'image_type,sha256,format', format($$'banner', %L, 'bmp'$$, pg_temp.h('e'))), 'image_format_fk');
SELECT pg_temp.t('unknown image type',          pg_temp.img('img_anime', 'image_type,sha256,format', format($$'wallpaper', %L, 'jpg'$$, pg_temp.h('e'))), 'image_type_fk');
SELECT pg_temp.t('same file, same type twice',  pg_temp.img('img_anime', 'image_type,sha256,format', format($$'cover', %L, 'jpg'$$, pg_temp.h('a'))), 'image_file_once_uq');
SELECT pg_temp.t('same file on another entity', pg_temp.img('img_game',  'image_type,sha256,format', format($$'cover', %L, 'jpg'$$, pg_temp.h('a'))), NULL);
SELECT pg_temp.t('JP box art with Japanese text', pg_temp.img('img_game', 'image_type,sha256,format,lang,region', format($$'box_art', %L, 'jpg', 'ja', 'JP'$$, pg_temp.h('f'))), NULL);
SELECT pg_temp.t('lowercase region',            pg_temp.img('img_game',  'image_type,sha256,format,region', format($$'box_art', %L, 'jpg', 'jp'$$, pg_temp.h('1'))), 'country_code_ck');
SELECT pg_temp.t('caption with native Japanese', pg_temp.img('img_game', 'image_type,sha256,format,caption', format($$'backdrop', %L, 'jpg', '{"en": {"text": "Tartarus", "native": false}, "ja": {"text": "タルタロス", "native": true}}'$$, pg_temp.h('2'))), NULL);
SELECT pg_temp.t('empty caption',               pg_temp.img('img_game',  'image_type,sha256,format,caption', format($$'backdrop', %L, 'jpg', '{}'$$, pg_temp.h('3'))), 'at least one language is required');
SELECT pg_temp.t('portrait on a person',        pg_temp.img('img_person', 'image_type,sha256,format,width,height,is_primary', format($$'portrait', %L, 'jpg', 225, 350, true$$, pg_temp.h('4'))), NULL);
SELECT pg_temp.t('icon on an age rating',       pg_temp.img('img_rating', 'image_type,sha256,format,is_primary', format($$'icon', %L, 'svg', true$$, pg_temp.h('5'))), NULL);
SELECT pg_temp.t('new format jxl is one row',   $$INSERT INTO core.image_format (code, mime_type) VALUES ('jxl', 'image/jxl')$$, NULL);
SELECT pg_temp.t('...and usable',               pg_temp.img('img_anime', 'image_type,sha256,format,width,height', format($$'thumbnail', %L, 'jxl', 320, 180$$, pg_temp.h('6'))), NULL);
SELECT pg_temp.t('format mime must be image/*', $$INSERT INTO core.image_format (code, mime_type) VALUES ('pdf', 'application/pdf')$$, 'image_format_mime_ck');
SELECT pg_temp.eq('covers in order, primary first', (SELECT string_agg(format || CASE WHEN is_primary THEN '*' ELSE '' END, ',' ORDER BY sort_order, id) FROM core.image WHERE entity_id = pg_temp.id('img_anime') AND image_type = 'cover'), 'jpg*,webp');
SELECT pg_temp.t('delete the anime',            format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('img_anime')), NULL);
SELECT pg_temp.eq('its images went; the game keeps the shared file',
  (SELECT count(*) FROM core.image WHERE entity_id = pg_temp.id('img_anime'))::text || '/' || (SELECT count(*) FROM core.image WHERE entity_id = pg_temp.id('img_game') AND sha256 = pg_temp.h('a'))::text, '0/1');

\echo '--- original languages and countries of origin'
INSERT INTO ids VALUES ('origin_anime', core.create_entity('anime')), ('origin_char', core.create_entity('character'));
INSERT INTO ids VALUES ('origin_ep', core.create_entity('episode', NULL, pg_temp.id('origin_anime')));
SELECT pg_temp.eq('origin attach kinds', (SELECT string_agg(kind, ',' ORDER BY kind) FROM core.attach_kind WHERE system = 'origin'), 'anime,game,light_novel,manga,movie,series');
SELECT pg_temp.t('Japanese and Korean original languages', format($$INSERT INTO core.entity_original_language (entity_id, entity_kind, lang, sort_order) VALUES (%1$s, 'anime', 'ja', 0), (%1$s, 'anime', 'ko', 1)$$, pg_temp.id('origin_anime')), NULL);
SELECT pg_temp.t('Japan and South Korea',      format($$INSERT INTO core.entity_origin_country (entity_id, entity_kind, country, sort_order) VALUES (%1$s, 'anime', 'JP', 0), (%1$s, 'anime', 'KR', 1)$$, pg_temp.id('origin_anime')), NULL);
SELECT pg_temp.t('same language twice',        format($$INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (%s, 'anime', 'ja')$$, pg_temp.id('origin_anime')), 'entity_original_language_pkey');
SELECT pg_temp.t('language name instead of tag', format($$INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (%s, 'anime', 'Japanese')$$, pg_temp.id('origin_anime')), 'lang_tag_ck');
SELECT pg_temp.t('lowercase country',          format($$INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (%s, 'anime', 'us')$$, pg_temp.id('origin_anime')), 'country_code_ck');
SELECT pg_temp.t('language on a character',    format($$INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (%s, 'character', 'ja')$$, pg_temp.id('origin_char')), 'entity_original_language_allowed_fk');
SELECT pg_temp.t('country on an episode',      format($$INSERT INTO core.entity_origin_country (entity_id, entity_kind, country) VALUES (%s, 'episode', 'JP')$$, pg_temp.id('origin_ep')), 'entity_origin_country_allowed_fk');
SELECT pg_temp.t('kind lies about entity',     format($$INSERT INTO core.entity_original_language (entity_id, entity_kind, lang) VALUES (%s, 'game', 'en')$$, pg_temp.id('origin_anime')), 'entity_original_language_entity_fk');
SELECT pg_temp.t('delete the episode, then the anime', format($$DELETE FROM core.entity WHERE id = %s; DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('origin_ep'), pg_temp.id('origin_anime')), NULL);
SELECT pg_temp.eq('its origins went with it',
  ((SELECT count(*) FROM core.entity_original_language WHERE entity_id = pg_temp.id('origin_anime')) + (SELECT count(*) FROM core.entity_origin_country WHERE entity_id = pg_temp.id('origin_anime')))::text, '0');

\echo '--- earlier layers still hold'
SELECT pg_temp.eq('every media entity has its work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('p3r'))))::text, pg_temp.id('p3r')::text);
