-- ============================================================================
-- Tests for migration 0007 — external data.
-- Run with db/test.sh (applies migrations 0001..0007 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- "Wrong kind" checks use entities with no rows yet, and delete checks use
-- entities with no children, so the rule under test is the one that fires.
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

-- one external rating row for a named fixture; extra columns optional
CREATE FUNCTION pg_temp.rate(n text, src text, met text, score text, cols text DEFAULT '', vals text DEFAULT '') RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO ext.rating (entity_id, entity_kind, source, metric, score%s)
                   SELECT e.id, e.kind, %L, %L, %s%s FROM core.entity e WHERE e.id = %s$f$,
                CASE WHEN cols = '' THEN '' ELSE ', ' || cols END, src, met, score,
                CASE WHEN vals = '' THEN '' ELSE ', ' || vals END, pg_temp.id(n)) $$;

CREATE FUNCTION pg_temp.link(n text, cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO ext.link (entity_id, entity_kind, %s)
                   SELECT e.id, e.kind, %s FROM core.entity e WHERE e.id = %s$f$, cols, vals, pg_temp.id(n)) $$;

\echo '--- sources, units and metrics'
SELECT pg_temp.eq('sources', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM ext.source), 'mal,anilist,imdb,rotten_tomatoes,metacritic,letterboxd,howlongtobeat');
SELECT pg_temp.eq('units',   (SELECT string_agg(code, ',' ORDER BY sort_order) FROM ext.unit), 'points,percent,hours');
SELECT pg_temp.eq('metrics', (SELECT count(*) FROM ext.metric)::text, '11');
SELECT pg_temp.eq('Rotten Tomatoes has critics and audience', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM ext.metric WHERE source = 'rotten_tomatoes'), 'critics,audience');
SELECT pg_temp.eq('MAL score scale',  (SELECT scale_min || '..' || scale_max || ' ' || unit FROM ext.metric WHERE source = 'mal' AND code = 'score'), '1.000..10.000 points');
SELECT pg_temp.eq('Letterboxd scale', (SELECT scale_min || '..' || scale_max FROM ext.metric WHERE source = 'letterboxd'), '0.500..5.000');
SELECT pg_temp.eq('playtime metrics have no scale', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM ext.metric WHERE unit = 'hours' AND scale_min IS NULL), 'main_story,main_extras,completionist');
SELECT pg_temp.eq('external data attaches to', (SELECT string_agg(kind, ',' ORDER BY kind) FROM core.attach_kind WHERE system = 'external'),
  'anime,cut,dlc,episode,game,light_novel,manga,movie,release,season,series,soundtrack,volume');
SELECT pg_temp.t('a new source is a row',        $$INSERT INTO ext.source (code, labels, homepage) VALUES ('vndb', core.label_en('VNDB'), 'https://vndb.org')$$, NULL);
SELECT pg_temp.t('...and a metric for it',       $$INSERT INTO ext.metric (source, code, labels, unit, scale_min, scale_max) VALUES ('vndb', 'rating', core.label_en('Rating'), 'points', 1, 10)$$, NULL);
SELECT pg_temp.t('a scale with only a minimum',  $$INSERT INTO ext.metric (source, code, labels, unit, scale_min) VALUES ('vndb', 'votes', core.label_en('x'), 'points', 1)$$, 'metric_scale_pair_ck');
SELECT pg_temp.t('a scale running backwards',    $$INSERT INTO ext.metric (source, code, labels, unit, scale_min, scale_max) VALUES ('vndb', 'backwards', core.label_en('x'), 'points', 10, 1)$$, 'metric_scale_order_ck');
SELECT pg_temp.t('a homepage that is not a URL', $$INSERT INTO ext.source (code, labels, homepage) VALUES ('bad', core.label_en('Bad'), 'vndb.org')$$, 'source_homepage_ck');
SELECT pg_temp.t('an unknown unit',              $$INSERT INTO ext.metric (source, code, labels, unit) VALUES ('vndb', 'length', core.label_en('Length'), 'minutes')$$, 'metric_unit_fk');

\echo '--- ratings and measurements'
INSERT INTO ids VALUES ('tora', core.create_entity('anime')), ('movie', core.create_entity('movie')),
  ('p3r', core.create_entity('game')), ('fresh_game', core.create_entity('game')), ('taiga', core.create_entity('character'));
INSERT INTO ids VALUES ('rel', core.create_entity('release', NULL, pg_temp.id('p3r')));
SELECT pg_temp.t('MAL 8.45 with votes and a URL', pg_temp.rate('tora', 'mal', 'score', '8.45', 'vote_count, source_url, recorded_on', $$512000, 'https://myanimelist.net/anime/4224', '2026-09-01'$$), NULL);
SELECT pg_temp.eq('...scale filled from the metric', (SELECT scale_min || '..' || scale_max FROM ext.rating WHERE entity_id = pg_temp.id('tora')), '1.000..10.000');
SELECT pg_temp.t('RT critics 93% on a movie',         pg_temp.rate('movie', 'rotten_tomatoes', 'critics', '93'), NULL);
SELECT pg_temp.t('RT audience 88% on the same movie', pg_temp.rate('movie', 'rotten_tomatoes', 'audience', '88'), NULL);
SELECT pg_temp.t('Letterboxd 3.9',                    pg_temp.rate('movie', 'letterboxd', 'rating', '3.9'), NULL);
SELECT pg_temp.t('HowLongToBeat main story 60.5 hours', pg_temp.rate('p3r', 'howlongtobeat', 'main_story', '60.5'), NULL);
SELECT pg_temp.eq('...no scale on an hours metric',   (SELECT coalesce(scale_min::text, 'none') FROM ext.rating WHERE entity_id = pg_temp.id('p3r') AND metric = 'main_story'), 'none');
SELECT pg_temp.t('Metacritic on a release',           pg_temp.rate('rel', 'metacritic', 'metascore', '89'), NULL);
SELECT pg_temp.t('an explicit scale override',        pg_temp.rate('tora', 'letterboxd', 'rating', '7.5', 'scale_min, scale_max', '0, 10'), NULL);
SELECT pg_temp.t('MAL 11 out of 10',                  pg_temp.rate('fresh_game', 'mal', 'score', '11'), 'rating_score_in_scale_ck');
SELECT pg_temp.t('MAL 0.5, below the minimum',        pg_temp.rate('fresh_game', 'mal', 'score', '0.5'), 'rating_score_in_scale_ck');
SELECT pg_temp.t('negative hours',                    pg_temp.rate('fresh_game', 'howlongtobeat', 'main_story', '-3'), 'rating_unscaled_not_negative_ck');
SELECT pg_temp.t('a scale with only a maximum',       pg_temp.rate('fresh_game', 'imdb', 'rating', '7', 'scale_max', '10'), 'rating_scale_pair_ck');
SELECT pg_temp.t('a metric that source lacks',        pg_temp.rate('fresh_game', 'imdb', 'score', '7'), 'rating_metric_fk');
SELECT pg_temp.t('an unknown source',                 pg_temp.rate('fresh_game', 'steam', 'score', '7'), 'rating_metric_fk');
SELECT pg_temp.t('a rating on a character',           pg_temp.rate('taiga', 'mal', 'score', '8'), 'rating_allowed_fk');
SELECT pg_temp.t('kind lies about the entity (a game with no rating yet)',
  format($$INSERT INTO ext.rating (entity_id, entity_kind, source, metric, score) VALUES (%s, 'anime', 'mal', 'score', 8)$$, pg_temp.id('fresh_game')), 'rating_entity_fk');
SELECT pg_temp.t('control: the same row with the right kind',
  format($$INSERT INTO ext.rating (entity_id, entity_kind, source, metric, score) VALUES (%s, 'game', 'mal', 'score', 8)$$, pg_temp.id('fresh_game')), NULL);
SELECT pg_temp.t('a URL without a scheme', pg_temp.rate('movie', 'imdb', 'rating', '7.8', 'source_url', $$'imdb.com/title/tt0111161'$$), 'rating_source_url_ck');
SELECT pg_temp.t('negative votes',         pg_temp.rate('movie', 'imdb', 'rating', '7.8', 'vote_count', '-1'), 'rating_vote_count_ck');

\echo '--- history and the latest value'
SELECT pg_temp.t('the same metric on the same date again', pg_temp.rate('tora', 'mal', 'score', '8.50', 'recorded_on', $$'2026-09-01'$$), 'rating_snapshot_uq');
SELECT pg_temp.t('an older snapshot', pg_temp.rate('tora', 'mal', 'score', '8.39', 'recorded_on', $$'2025-01-10'$$), NULL);
SELECT pg_temp.t('a newer snapshot',  pg_temp.rate('tora', 'mal', 'score', '8.47', 'recorded_on', $$'2026-09-15'$$), NULL);
SELECT pg_temp.eq('history in order', (SELECT string_agg(score::text, ' -> ' ORDER BY recorded_on) FROM ext.rating WHERE entity_id = pg_temp.id('tora') AND source = 'mal'), '8.390 -> 8.450 -> 8.470');
SELECT pg_temp.eq('latest MAL score', (SELECT score || ' on ' || recorded_on FROM ext.rating_latest WHERE entity_id = pg_temp.id('tora') AND source = 'mal'), '8.470 on 2026-09-15');
SELECT pg_temp.eq('one latest row per metric', (SELECT string_agg(source || '/' || metric || '=' || score, ' ' ORDER BY source, metric) FROM ext.rating_latest WHERE entity_id = pg_temp.id('movie')),
  'letterboxd/rating=3.900 rotten_tomatoes/audience=88.000 rotten_tomatoes/critics=93.000');
SELECT pg_temp.eq('recorded date defaults to today', (SELECT (recorded_on = current_date)::text FROM ext.rating WHERE entity_id = pg_temp.id('movie') AND metric = 'critics'), 'true');

\echo '--- links'
INSERT INTO ids VALUES ('manga', core.create_entity('manga')), ('fresh_link_game', core.create_entity('game')),
  ('atlus', core.create_entity('company'));
INSERT INTO ids VALUES ('vol', core.create_entity('volume', NULL, pg_temp.id('manga'))),
  ('ost', core.create_entity('soundtrack', NULL, pg_temp.id('tora')));
SELECT pg_temp.t('a MAL page with its source',  pg_temp.link('tora', 'source, url, sort_order', $$'mal', 'https://myanimelist.net/anime/4224', 0$$), NULL);
SELECT pg_temp.t('an official site, no source', pg_temp.link('tora', 'url, caption, lang, sort_order', $$'https://www.tigerxdragon.jp', '{"en": {"text": "Official site", "native": false}, "ja": {"text": "公式サイト", "native": true}}', 'ja', 1$$), NULL);
SELECT pg_temp.t('a regional store link on a release', pg_temp.link('rel', 'url, caption, region', $$'https://store.playstation.com/ja-jp/product/EP0177', '{"en": {"text": "PlayStation Store", "native": false}}', 'JP'$$), NULL);
SELECT pg_temp.t('a link on a volume',          pg_temp.link('vol', 'url', $$'https://www.example.jp/volume1'$$), NULL);
SELECT pg_temp.t('a link on a soundtrack',      pg_temp.link('ost', 'url', $$'https://vgmdb.net/album/12345'$$), NULL);
SELECT pg_temp.t('the same URL twice on one entity', pg_temp.link('tora', 'url', $$'https://myanimelist.net/anime/4224'$$), 'link_url_uq');
SELECT pg_temp.t('the same URL on another entity',   pg_temp.link('p3r', 'url', $$'https://myanimelist.net/anime/4224'$$), NULL);
SELECT pg_temp.t('a URL without a scheme',      pg_temp.link('p3r', 'url', $$'store.steampowered.com/app/2161700'$$), 'link_url_ck');
SELECT pg_temp.t('a URL with a space',          pg_temp.link('p3r', 'url', $$'https://example.com/a b'$$), 'link_url_ck');
SELECT pg_temp.t('an unknown source',           pg_temp.link('p3r', 'source, url', $$'steam', 'https://store.steampowered.com/app/2161700'$$), 'link_source_fk');
SELECT pg_temp.t('a lowercase region',          pg_temp.link('p3r', 'url, region', $$'https://example.com/r', 'jp'$$), 'country_code_ck');
SELECT pg_temp.t('an empty caption',            pg_temp.link('p3r', 'url, caption', $$'https://example.com/c', '{}'$$), 'at least one language is required');
SELECT pg_temp.t('a link on a character',       pg_temp.link('taiga', 'url', $$'https://example.com/taiga'$$), 'link_allowed_fk');
SELECT pg_temp.t('a link on a company',         pg_temp.link('atlus', 'url', $$'https://atlus.com'$$), 'link_allowed_fk');
SELECT pg_temp.t('kind lies about the entity (a game with no links yet)',
  format($$INSERT INTO ext.link (entity_id, entity_kind, url) VALUES (%s, 'anime', 'https://example.com/g')$$, pg_temp.id('fresh_link_game')), 'link_entity_fk');
SELECT pg_temp.t('control: the same link with the right kind',
  format($$INSERT INTO ext.link (entity_id, entity_kind, url) VALUES (%s, 'game', 'https://example.com/g')$$, pg_temp.id('fresh_link_game')), NULL);
SELECT pg_temp.t('a store added as a source row', $$INSERT INTO ext.source (code, labels, homepage) VALUES ('steam', core.label_en('Steam'), 'https://store.steampowered.com')$$, NULL);
SELECT pg_temp.t('...then linked',               pg_temp.link('p3r', 'source, url', $$'steam', 'https://store.steampowered.com/app/2161700'$$), NULL);
SELECT pg_temp.eq('links on the anime in order', (SELECT string_agg(coalesce(source, '-') || ' ' || url, ' | ' ORDER BY sort_order) FROM ext.link WHERE entity_id = pg_temp.id('tora')),
  'mal https://myanimelist.net/anime/4224 | - https://www.tigerxdragon.jp');

\echo '--- renames and deletes'
SELECT pg_temp.t('rename source mal to myanimelist', $$UPDATE ext.source SET code = 'myanimelist' WHERE code = 'mal'$$, NULL);
SELECT pg_temp.eq('...ratings follow, scale kept', (SELECT DISTINCT source || ' ' || scale_min || '..' || scale_max FROM ext.rating WHERE entity_id = pg_temp.id('tora') AND metric = 'score'), 'myanimelist 1.000..10.000');
SELECT pg_temp.eq('...links follow',               (SELECT source FROM ext.link WHERE entity_id = pg_temp.id('tora') AND url LIKE '%myanimelist%'), 'myanimelist');
SELECT pg_temp.t('delete a source that has ratings', $$DELETE FROM ext.source WHERE code = 'letterboxd'$$, 'rating_metric_fk');
SELECT pg_temp.t('delete a source a link uses',      $$DELETE FROM ext.source WHERE code = 'steam'$$, 'link_source_fk');
SELECT pg_temp.t('delete a source nobody used',      $$DELETE FROM ext.source WHERE code = 'vndb'$$, NULL);
SELECT pg_temp.eq('...its metric went with it',      (SELECT count(*) FROM ext.metric WHERE source = 'vndb')::text, '0');
SELECT pg_temp.t('delete the soundtrack (no children)', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ost')), NULL);
SELECT pg_temp.t('delete the movie (no children)',      format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('movie')), NULL);
SELECT pg_temp.eq('their ratings and links went',
  ((SELECT count(*) FROM ext.link WHERE entity_id IN (pg_temp.id('ost'), pg_temp.id('movie')))
 + (SELECT count(*) FROM ext.rating WHERE entity_id IN (pg_temp.id('ost'), pg_temp.id('movie'))))::text, '0');

\echo '--- earlier layers still hold'
SELECT pg_temp.eq('every media entity has its work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('p3r'))))::text, pg_temp.id('p3r')::text);
