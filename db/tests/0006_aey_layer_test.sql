-- ============================================================================
-- Tests for migration 0006 — the Aey layer.
-- Run with db/test.sh (applies migrations 0001..0006 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- Each section creates its own fixtures; entities used in delete checks have no
-- children, and entities used in "wrong kind" checks carry no row yet, so the
-- rule under test is the one that fires.
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

CREATE FUNCTION pg_temp.score(n text, v int) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO aey.score (entity_id, entity_kind, general)
                   SELECT e.id, e.kind, %s FROM core.entity e WHERE e.id = %s$f$, v, pg_temp.id(n)) $$;

CREATE FUNCTION pg_temp.sub(n text, cat text, v int) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO aey.subrating (entity_id, entity_kind, category, value)
                   SELECT e.id, e.kind, %L, %s FROM core.entity e WHERE e.id = %s$f$, cat, v, pg_temp.id(n)) $$;

CREATE FUNCTION pg_temp.take(n text, l text, body text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO aey.take (entity_id, entity_kind, lang, body)
                   SELECT e.id, e.kind, %L, %L FROM core.entity e WHERE e.id = %s$f$, l, body, pg_temp.id(n)) $$;

CREATE FUNCTION pg_temp.prog(n text, cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO aey.progress (entity_id, entity_kind, %s)
                   SELECT e.id, e.kind, %s FROM core.entity e WHERE e.id = %s$f$, cols, vals, pg_temp.id(n)) $$;

\echo '--- which kinds can be rated'
SELECT pg_temp.eq('rateable kinds', (SELECT string_agg(name, ',' ORDER BY name) FROM core.entity_kind WHERE rateable),
  'anime,character,cut,dlc,episode,game,light_novel,manga,movie,season,series,soundtrack,volume');
SELECT pg_temp.eq('how many', (SELECT count(*) FROM core.entity_kind WHERE rateable)::text, '13');
SELECT pg_temp.eq('not rateable', (SELECT string_agg(name, ',' ORDER BY name) FROM core.entity_kind WHERE NOT rateable),
  'age_rating,age_rating_system,company,franchise,genre,person,platform,platform_family,release,tag');
SELECT pg_temp.eq('no favourite flag anywhere (rankings derive from the score)',
  (SELECT count(*)::text FROM information_schema.columns WHERE table_schema IN ('aey', 'core', 'media', 'child', 'world') AND column_name ~ 'favou?rite'), '0');

\echo '--- the score type and its display'
SELECT pg_temp.t('+50', $$SELECT 50::core.score_50$$, NULL);
SELECT pg_temp.t('-50', $$SELECT (-50)::core.score_50$$, NULL);
SELECT pg_temp.t('+51', $$SELECT 51::core.score_50$$, 'score_50_ck');
SELECT pg_temp.t('-51', $$SELECT (-51)::core.score_50$$, 'score_50_ck');
SELECT pg_temp.eq('+32 shows as',         aey.score_shown(32)::text,  '6.4');
SELECT pg_temp.eq('+32 fills half-stars', aey.half_stars(32)::text,   '6');
SELECT pg_temp.eq('+35 fills half-stars', aey.half_stars(35)::text,   '7');
SELECT pg_temp.eq('-15 shows as',         aey.score_shown(-15)::text, '-3.0');
SELECT pg_temp.eq('-15 fills half-stars', aey.half_stars(-15)::text,  '-3');
SELECT pg_temp.eq('+4 fills no star',     aey.half_stars(4)::text,    '0');
SELECT pg_temp.eq('+50 is five stars',    aey.half_stars(50)::text,   '10');
SELECT pg_temp.eq('-50 is five negative stars', aey.half_stars(-50)::text, '-10');
SELECT pg_temp.eq('every step of 5 adds half a star',
  (SELECT string_agg(aey.half_stars(s)::text, ',' ORDER BY s) FROM generate_series(0, 50, 5) AS s), '0,1,2,3,4,5,6,7,8,9,10');

\echo '--- General Score'
INSERT INTO ids VALUES ('p3r', core.create_entity('game')), ('p3p', core.create_entity('game')), ('undertale', core.create_entity('game')),
  ('fresh_game', core.create_entity('game')), ('anime', core.create_entity('anime')), ('taiga', core.create_entity('character')),
  ('atlus', core.create_entity('company')), ('rpg', core.create_entity('genre')), ('romance', core.create_entity('genre'));
INSERT INTO ids VALUES ('ep', core.create_entity('episode', NULL, pg_temp.id('anime'))),
  ('rel', core.create_entity('release', NULL, pg_temp.id('p3p'))),
  ('ost', core.create_entity('soundtrack', NULL, pg_temp.id('anime')));
SELECT pg_temp.t('P3R +32',       pg_temp.score('p3r', 32), NULL);
SELECT pg_temp.t('P3P +46',       pg_temp.score('p3p', 46), NULL);
SELECT pg_temp.t('Undertale +48', pg_temp.score('undertale', 48), NULL);
SELECT pg_temp.t('a character',   pg_temp.score('taiga', 40), NULL);
SELECT pg_temp.t('an episode',    pg_temp.score('ep', 25), NULL);
SELECT pg_temp.t('a soundtrack',  pg_temp.score('ost', -10), NULL);
SELECT pg_temp.t('a release',     pg_temp.score('rel', 10), 'score_rateable_fk');
SELECT pg_temp.t('a company',     pg_temp.score('atlus', 10), 'score_rateable_fk');
SELECT pg_temp.t('a genre',       pg_temp.score('rpg', 10), 'score_rateable_fk');
SELECT pg_temp.t('over +50',      pg_temp.score('anime', 60), 'score_50_ck');
SELECT pg_temp.t('scored twice',  pg_temp.score('p3r', 20), 'score_pkey');
SELECT pg_temp.t('kind lies about the entity (a game with no score yet)',
  format($$INSERT INTO aey.score (entity_id, entity_kind, general) VALUES (%s, 'anime', 5)$$, pg_temp.id('fresh_game')), 'score_entity_fk');
SELECT pg_temp.t('control: the same row with the right kind',
  format($$INSERT INTO aey.score (entity_id, entity_kind, general) VALUES (%s, 'game', 5)$$, pg_temp.id('fresh_game')), NULL);
SELECT pg_temp.eq('top games, derived from the score',
  (SELECT string_agg(i.name || ' ' || aey.score_shown(s.general), ', ' ORDER BY s.general DESC)
     FROM aey.score s JOIN ids i ON i.id = s.entity_id WHERE s.entity_kind = 'game'),
  'undertale 9.6, p3p 9.2, p3r 6.4, fresh_game 1.0');

\echo '--- subratings'
SELECT pg_temp.eq('starter categories', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM aey.subrating_category),
  'story,characters,pacing,art,animation,music,gameplay,world');
SELECT pg_temp.t('gameplay suggested for games',    $$INSERT INTO aey.subrating_suggestion (category, kind) VALUES ('gameplay', 'game')$$, NULL);
SELECT pg_temp.t('animation suggested for anime',   $$INSERT INTO aey.subrating_suggestion (category, kind) VALUES ('animation', 'anime')$$, NULL);
SELECT pg_temp.t('characters suggested for Romance', format($$INSERT INTO aey.subrating_suggestion (category, genre_id) VALUES ('characters', %s)$$, pg_temp.id('romance')), NULL);
SELECT pg_temp.t('both a medium and a genre',       format($$INSERT INTO aey.subrating_suggestion (category, kind, genre_id) VALUES ('story', 'game', %s)$$, pg_temp.id('rpg')), 'subrating_suggestion_one_target_ck');
SELECT pg_temp.t('neither',                         $$INSERT INTO aey.subrating_suggestion (category) VALUES ('story')$$, 'subrating_suggestion_one_target_ck');
SELECT pg_temp.t('the same suggestion twice',       $$INSERT INTO aey.subrating_suggestion (category, kind) VALUES ('gameplay', 'game')$$, 'subrating_suggestion_uq');
SELECT pg_temp.t('a company as the genre',          format($$INSERT INTO aey.subrating_suggestion (category, genre_id) VALUES ('music', %s)$$, pg_temp.id('atlus')), 'subrating_suggestion_genre_fk');
SELECT pg_temp.t('P3R gameplay +40',                pg_temp.sub('p3r', 'gameplay', 40), NULL);
SELECT pg_temp.t('P3R music +35',                   pg_temp.sub('p3r', 'music', 35), NULL);
SELECT pg_temp.t('P3R pacing -15',                  pg_temp.sub('p3r', 'pacing', -15), NULL);
SELECT pg_temp.t('a category nobody suggested',     pg_temp.sub('p3r', 'world', 20), NULL);
SELECT pg_temp.t('gameplay on an episode',          pg_temp.sub('ep', 'gameplay', 5), NULL);
SELECT pg_temp.t('the same category twice',         pg_temp.sub('p3r', 'music', 10), 'subrating_pkey');
SELECT pg_temp.t('an unknown category',             pg_temp.sub('p3r', 'vibes', 10), 'subrating_category_fk');
SELECT pg_temp.t('a subrating on a release',        pg_temp.sub('rel', 'music', 10), 'subrating_rateable_fk');
SELECT pg_temp.t('a subrating with no General Score', pg_temp.sub('anime', 'art', 30), NULL);
SELECT pg_temp.eq('subratings never move the General Score',
  (SELECT (SELECT general FROM aey.score WHERE entity_id = pg_temp.id('p3r'))::text || ' vs average ' || round(avg(value))::text
     FROM aey.subrating WHERE entity_id = pg_temp.id('p3r')), '32 vs average 20');

\echo '--- Aey''s Take'
SELECT pg_temp.t('an English take',  pg_temp.take('p3r', 'en', 'Tries to be Persona 5, and that does not fit Persona 3 tone.'), NULL);
SELECT pg_temp.t('a Turkish take',   pg_temp.take('p3r', 'tr', 'Persona 5 olmaya calisiyor.'), NULL);
SELECT pg_temp.t('the same language twice', pg_temp.take('p3r', 'en', 'Again.'), 'take_pkey');
SELECT pg_temp.t('an empty take',    pg_temp.take('p3r', 'ja', '   '), 'take_body_ck');
SELECT pg_temp.t('a take on a company', pg_temp.take('atlus', 'en', 'x'), 'take_rateable_fk');
SELECT pg_temp.t('a take on a character', pg_temp.take('taiga', 'en', 'Best girl.'), NULL);
SELECT pg_temp.eq('takes on P3R', (SELECT string_agg(lang, ',' ORDER BY lang) FROM aey.take WHERE entity_id = pg_temp.id('p3r')), 'en,tr');

\echo '--- progress and history'
INSERT INTO ids VALUES ('played', core.create_entity('game')), ('unplayed', core.create_entity('game')),
  ('manga', core.create_entity('manga')), ('series', core.create_entity('series')), ('movie', core.create_entity('movie')),
  ('family', core.create_entity('platform_family'));
INSERT INTO ids VALUES ('season', core.create_entity('season', NULL, pg_temp.id('series'))),
  ('ps2', core.create_entity('platform', NULL, pg_temp.id('family'))),
  ('ps5', core.create_entity('platform', NULL, pg_temp.id('family')));
SELECT pg_temp.eq('statuses', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM aey.status), 'planning,in_progress,on_hold,completed,revisiting,dropped');
SELECT pg_temp.eq('progress attaches to', (SELECT string_agg(kind, ',' ORDER BY kind) FROM core.attach_kind WHERE system = 'progress'), 'anime,game,light_novel,manga,movie,season,series');
SELECT pg_temp.t('a finished game: 94 hours, 2 playthroughs', pg_temp.prog('played', 'status,started_on,finished_on,times_completed,time_spent_s', $$'completed','2024-02-04','2024-03-18',2,338400$$), NULL);
SELECT pg_temp.t('an anime in progress: episode 12', pg_temp.prog('anime', 'status,progress_value,progress_unit,started_on', $$'in_progress',12,'episode','2026-09'$$), NULL);
SELECT pg_temp.t('a manga at chapter 45.5',         pg_temp.prog('manga', 'status,progress_value,progress_unit', $$'in_progress',45.5,'chapter'$$), NULL);
SELECT pg_temp.t('a season on hold',                pg_temp.prog('season', 'status', $$'on_hold'$$), NULL);
SELECT pg_temp.t('a planned movie',                 pg_temp.prog('movie', 'status', $$'planning'$$), NULL);
SELECT pg_temp.t('progress on an episode',          pg_temp.prog('ep', 'status', $$'completed'$$), 'progress_allowed_fk');
SELECT pg_temp.t('progress on a character',         pg_temp.prog('taiga', 'status', $$'completed'$$), 'progress_allowed_fk');
SELECT pg_temp.t('a number with no unit',           pg_temp.prog('unplayed', 'status,progress_value', $$'in_progress',3$$), 'progress_value_needs_unit_ck');
SELECT pg_temp.t('an unknown status',               pg_temp.prog('unplayed', 'status', $$'binging'$$), 'progress_status_fk');
SELECT pg_temp.t('an unknown unit',                 pg_temp.prog('unplayed', 'progress_value,progress_unit', $$3,'level'$$), 'progress_unit_fk');
SELECT pg_temp.t('finished before started',         pg_temp.prog('unplayed', 'started_on,finished_on', $$'2024-03','2024-01'$$), 'progress_dates_order_ck');
SELECT pg_temp.t('negative playthroughs',           pg_temp.prog('unplayed', 'times_completed', $$-1$$), 'progress_times_completed_ck');
SELECT pg_temp.t('zero playtime',                   pg_temp.prog('unplayed', 'time_spent_s', $$0$$), 'progress_time_spent_ck');
SELECT pg_temp.t('a second progress row',           pg_temp.prog('played', 'status', $$'dropped'$$), 'progress_pkey');
SELECT pg_temp.eq('the anime reads back', (SELECT status || ' ' || progress_value || ' ' || progress_unit || ' from ' || started_on FROM aey.progress WHERE entity_id = pg_temp.id('anime')), 'in_progress 12.00 episode from 2026-09');
SELECT pg_temp.eq('playtime in hours', (SELECT round(time_spent_s / 3600.0, 1)::text FROM aey.progress WHERE entity_id = pg_temp.id('played')), '94.0');
SELECT pg_temp.t('played on PS2 and PS5', format($$INSERT INTO aey.progress_platform (entity_id, platform_id) VALUES (%1$s, %2$s), (%1$s, %3$s)$$, pg_temp.id('played'), pg_temp.id('ps2'), pg_temp.id('ps5')), NULL);
SELECT pg_temp.t('the same platform twice',  format($$INSERT INTO aey.progress_platform (entity_id, platform_id) VALUES (%s, %s)$$, pg_temp.id('played'), pg_temp.id('ps2')), 'progress_platform_pkey');
SELECT pg_temp.t('an anime as the platform', format($$INSERT INTO aey.progress_platform (entity_id, platform_id) VALUES (%s, %s)$$, pg_temp.id('played'), pg_temp.id('anime')), 'progress_platform_platform_fk');
SELECT pg_temp.t('platforms without a progress row', format($$INSERT INTO aey.progress_platform (entity_id, platform_id) VALUES (%s, %s)$$, pg_temp.id('unplayed'), pg_temp.id('ps2')), 'progress_platform_progress_fk');
SELECT pg_temp.t('delete a platform that was played on', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ps2')), 'progress_platform_platform_fk');
SELECT pg_temp.eq('platforms of the game', (SELECT string_agg(i.name, ',' ORDER BY i.name) FROM aey.progress_platform p JOIN ids i ON i.id = p.platform_id WHERE p.entity_id = pg_temp.id('played')), 'ps2,ps5');

\echo '--- deletes'
SELECT pg_temp.eq('P3R rows before', ((SELECT count(*) FROM aey.score WHERE entity_id = pg_temp.id('p3r'))
  + (SELECT count(*) FROM aey.subrating WHERE entity_id = pg_temp.id('p3r'))
  + (SELECT count(*) FROM aey.take WHERE entity_id = pg_temp.id('p3r')))::text, '7');
SELECT pg_temp.t('delete P3R (it has no children)', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('p3r')), NULL);
SELECT pg_temp.eq('its score, subratings and takes went',
  ((SELECT count(*) FROM aey.score WHERE entity_id = pg_temp.id('p3r'))
 + (SELECT count(*) FROM aey.subrating WHERE entity_id = pg_temp.id('p3r'))
 + (SELECT count(*) FROM aey.take WHERE entity_id = pg_temp.id('p3r')))::text, '0');
SELECT pg_temp.t('delete P3P while its release is there', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('p3p')), 'entity_parent_fk');
SELECT pg_temp.t('delete the release first, then P3P', format($$DELETE FROM core.entity WHERE parent_id = %1$s; DELETE FROM core.entity WHERE id = %1$s$$, pg_temp.id('p3p')), NULL);
SELECT pg_temp.t('delete the played game', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('played')), NULL);
SELECT pg_temp.eq('its progress and platforms went',
  ((SELECT count(*) FROM aey.progress WHERE entity_id = pg_temp.id('played'))
 + (SELECT count(*) FROM aey.progress_platform WHERE entity_id = pg_temp.id('played')))::text, '0');
SELECT pg_temp.t('delete the Romance genre', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('romance')), NULL);
SELECT pg_temp.eq('its suggestion went too', (SELECT count(*) FROM aey.subrating_suggestion WHERE genre_id = pg_temp.id('romance'))::text, '0');

\echo '--- earlier layers still hold'
SELECT pg_temp.eq('every media entity has its work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('anime'))))::text, pg_temp.id('anime')::text);
