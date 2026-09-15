-- ============================================================================
-- Tests for migration 0002 — primary media.
-- Run with db/test.sh (applies migrations 0001..0002 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- Not covered here: the backfill of media entities created before 0002 (needs
-- data between migrations); it was verified while building 0002.
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

-- INSERT a schedule row for a named fixture; cols/vals exclude entity_id and kind.
CREATE FUNCTION pg_temp.cad(n text, cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO media.cadence_period (entity_id, kind, %s) SELECT id, kind, %s FROM core.entity WHERE id = %s',
                cols, vals, pg_temp.id(n)) $$;

CREATE FUNCTION pg_temp.cols(tbl text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
   WHERE table_schema = 'media' AND table_name = tbl $$;

-- ----------------------------------------------------------------------------
-- Fixtures: one entity of every kind
-- ----------------------------------------------------------------------------
INSERT INTO ids VALUES ('anime',  core.create_entity('anime'));
INSERT INTO ids VALUES ('manga',  core.create_entity('manga'));
INSERT INTO ids VALUES ('ln',     core.create_entity('light_novel'));
INSERT INTO ids VALUES ('game',   core.create_entity('game'));
INSERT INTO ids VALUES ('series', core.create_entity('series'));
INSERT INTO ids VALUES ('movie',  core.create_entity('movie'));
INSERT INTO ids VALUES ('season', core.create_entity('season',     NULL, pg_temp.id('series')));
INSERT INTO ids VALUES ('ep',     core.create_entity('episode',    NULL, pg_temp.id('season')));
INSERT INTO ids VALUES ('volume', core.create_entity('volume',     NULL, pg_temp.id('manga')));
INSERT INTO ids VALUES ('dlc',    core.create_entity('dlc',        NULL, pg_temp.id('game')));
INSERT INTO ids VALUES ('rel',    core.create_entity('release',    NULL, pg_temp.id('movie')));
INSERT INTO ids VALUES ('cut',    core.create_entity('cut',        NULL, pg_temp.id('movie')));
INSERT INTO ids VALUES ('ost',    core.create_entity('soundtrack', NULL, pg_temp.id('game')));
INSERT INTO ids VALUES ('char',   core.create_entity('character'));
INSERT INTO ids VALUES ('person', core.create_entity('person'));
INSERT INTO ids VALUES ('comp',   core.create_entity('company'));

\echo '--- labels'
SELECT pg_temp.t('one language, any language',  $$SELECT '{"tr": {"text": "Dizi", "native": false}}'::core.labels$$, NULL);
SELECT pg_temp.t('native Japanese label',       $$SELECT '{"en": {"text": "TV", "native": false}, "ja": {"text": "テレビ", "native": true}}'::core.labels$$, NULL);
SELECT pg_temp.t('romaji tag ja-Latn',          $$SELECT '{"ja-Latn": {"text": "terebi", "native": false}}'::core.labels$$, NULL);
SELECT pg_temp.t('no language',                 $$SELECT '{}'::core.labels$$, 'at least one language is required');
SELECT pg_temp.t('not an object',               $$SELECT '["TV"]'::core.labels$$, 'must be an object keyed by language');
SELECT pg_temp.t('bad language tag',            $$SELECT '{"EN": {"text": "TV", "native": false}}'::core.labels$$, 'is not a language tag');
SELECT pg_temp.t('missing native flag',         $$SELECT '{"en": {"text": "TV"}}'::core.labels$$, 'needs native true or false');
SELECT pg_temp.t('blank text',                  $$SELECT '{"en": {"text": " ", "native": false}}'::core.labels$$, 'needs non-empty text');
SELECT pg_temp.t('extra key',                   $$SELECT '{"en": {"text": "TV", "native": false, "x": 1}}'::core.labels$$, 'may only contain text and native');
SELECT pg_temp.t('two native labels',           $$SELECT '{"en": {"text": "TV", "native": true}, "ja": {"text": "テレビ", "native": true}}'::core.labels$$, 'at most one language can be native');

\echo '--- partial dates and seconds'
SELECT pg_temp.t('YYYY',              $$SELECT '2006'::core.partial_date$$, NULL);
SELECT pg_temp.t('YYYY-MM',           $$SELECT '2006-07'::core.partial_date$$, NULL);
SELECT pg_temp.t('leap day 2024',     $$SELECT '2024-02-29'::core.partial_date$$, NULL);
SELECT pg_temp.t('no leap day 2023',  $$SELECT '2023-02-29'::core.partial_date$$, 'is not a real calendar date');
SELECT pg_temp.t('month 13',          $$SELECT '2006-13'::core.partial_date$$, 'month out of range');
SELECT pg_temp.t('year 0000',         $$SELECT '0000'::core.partial_date$$, 'year out of range');
SELECT pg_temp.t('slashes',           $$SELECT '2006/07/13'::core.partial_date$$, 'is not YYYY, YYYY-MM or YYYY-MM-DD');
SELECT pg_temp.eq('2006-07-13 .. 2006 is ordered', core.partial_date_ordered('2006-07-13', '2006')::text, 'true');
SELECT pg_temp.eq('2006 .. 2005-12 is not',        core.partial_date_ordered('2006', '2005-12')::text, 'false');
SELECT pg_temp.t('zero seconds',      $$SELECT 0::core.seconds$$, 'seconds_ck');

\echo '--- option lists'
CREATE TEMP VIEW matrix AS
  SELECT k.kind, string_agg(k.status, ',' ORDER BY s.sort_order) AS statuses
    FROM media.work_status_kind k JOIN media.work_status s ON s.code = k.status GROUP BY k.kind;
SELECT pg_temp.eq('anime statuses',       (SELECT statuses FROM matrix WHERE kind = 'anime'),       'upcoming,airing,finished,hiatus,cancelled');
SELECT pg_temp.eq('series statuses',      (SELECT statuses FROM matrix WHERE kind = 'series'),      'upcoming,airing,finished,hiatus,cancelled');
SELECT pg_temp.eq('manga statuses',       (SELECT statuses FROM matrix WHERE kind = 'manga'),       'upcoming,publishing,finished,hiatus,cancelled');
SELECT pg_temp.eq('light novel statuses', (SELECT statuses FROM matrix WHERE kind = 'light_novel'), 'upcoming,publishing,finished,hiatus,cancelled');
SELECT pg_temp.eq('game statuses',        (SELECT statuses FROM matrix WHERE kind = 'game'),        'announced,early_access,released,cancelled');
SELECT pg_temp.eq('movie statuses',       (SELECT statuses FROM matrix WHERE kind = 'movie'),       'announced,released,cancelled');
SELECT pg_temp.eq('anime formats',        (SELECT string_agg(code, ',' ORDER BY sort_order) FROM media.anime_format), 'tv,ova,ona,movie,special,music_video,short');
SELECT pg_temp.eq('source types',         (SELECT count(*) FROM media.source_type)::text, '12');
SELECT pg_temp.t('status pair on a child kind',   $$INSERT INTO media.work_status_kind (status, kind) VALUES ('airing', 'season')$$, 'work_status_kind_kind_fk');
SELECT pg_temp.t('option code must be lowercase', $$INSERT INTO media.source_type (code, labels) VALUES ('Fanfic', core.label_en('Fanfic'))$$, 'source_type_code_ck');
SELECT pg_temp.t('option labels are validated',   $$INSERT INTO media.anime_format (code, labels) VALUES ('pv', '{}')$$, 'at least one language is required');

\echo '--- media.work'
SELECT pg_temp.eq('every media entity has one work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id AND w.kind = e.kind WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('no work rows for child or world', (SELECT count(*) FROM media.work w JOIN core.entity e ON e.id = w.entity_id WHERE e.family <> 'media')::text, '0');
SELECT pg_temp.t('anime airing',          format($$UPDATE media.work SET status = 'airing' WHERE entity_id = %s$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('game early access',     format($$UPDATE media.work SET status = 'early_access' WHERE entity_id = %s$$, pg_temp.id('game')), NULL);
SELECT pg_temp.t('game airing',           format($$UPDATE media.work SET status = 'airing' WHERE entity_id = %s$$, pg_temp.id('game')), 'work_status_allowed_fk');
SELECT pg_temp.t('movie early access',    format($$UPDATE media.work SET status = 'early_access' WHERE entity_id = %s$$, pg_temp.id('movie')), 'work_status_allowed_fk');
SELECT pg_temp.t('light novel airing',    format($$UPDATE media.work SET status = 'airing' WHERE entity_id = %s$$, pg_temp.id('ln')), 'work_status_allowed_fk');
SELECT pg_temp.t('aired 2006-10 .. 2007-03', format($$UPDATE media.work SET start_date = '2006-10', end_date = '2007-03' WHERE entity_id = %s$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('end before start',      format($$UPDATE media.work SET start_date = '2006', end_date = '2005-12' WHERE entity_id = %s$$, pg_temp.id('manga')), 'work_dates_order_ck');
SELECT pg_temp.t('source light novel',    format($$UPDATE media.work SET source_type = 'light_novel' WHERE entity_id = %s$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('unknown source',        format($$UPDATE media.work SET source_type = 'fanfic' WHERE entity_id = %s$$, pg_temp.id('anime')), 'work_source_type_fk');
SELECT pg_temp.t('work row for a person', format($$INSERT INTO media.work (entity_id, kind) VALUES (%s, 'person')$$, pg_temp.id('person')), 'work_kind_family_fk');
WITH x AS (INSERT INTO core.entity (kind, family, scope, seq, franchise_id)
           VALUES ('anime', 'media', 'franchise', 900, (SELECT franchise_id FROM core.entity WHERE id = pg_temp.id('anime'))) RETURNING id)
INSERT INTO ids SELECT 'raw', id FROM x;
SELECT pg_temp.eq('raw media insert gets a work row', (SELECT count(*) FROM media.work WHERE entity_id = pg_temp.id('raw'))::text, '1');
SELECT pg_temp.t('kind change blocked by work row',  format($$UPDATE core.entity SET kind = 'game' WHERE id = %s$$, pg_temp.id('raw')), 'work_entity_fk');

\echo '--- type-specific fields'
SELECT pg_temp.eq('anime columns',       pg_temp.cols('anime'),       'entity_id,kind,format,episode_count,typical_runtime_s');
SELECT pg_temp.eq('manga columns',       pg_temp.cols('manga'),       'entity_id,kind,volume_count,chapter_count');
SELECT pg_temp.eq('light novel columns', pg_temp.cols('light_novel'), 'entity_id,kind,volume_count');
SELECT pg_temp.eq('game columns',        pg_temp.cols('game'),        'entity_id,kind,local_players_min,local_players_max,online_players_min,online_players_max');
SELECT pg_temp.eq('series columns',      pg_temp.cols('series'),      'entity_id,kind,episode_count,typical_runtime_s');
SELECT pg_temp.eq('movie columns',       pg_temp.cols('movie'),       'entity_id,kind,runtime_s');
SELECT pg_temp.t('anime TV, 25 episodes, 24 min', format($$UPDATE media.anime SET format = 'tv', episode_count = 25, typical_runtime_s = 1440 WHERE entity_id = %s$$, pg_temp.id('anime')), NULL);
SELECT pg_temp.t('unknown anime format',   format($$UPDATE media.anime SET format = 'webtoon' WHERE entity_id = %s$$, pg_temp.id('anime')), 'anime_format_fk');
SELECT pg_temp.t('negative episode count', format($$UPDATE media.anime SET episode_count = -1 WHERE entity_id = %s$$, pg_temp.id('anime')), 'anime_episode_count_ck');
SELECT pg_temp.t('negative chapter count', format($$UPDATE media.manga SET chapter_count = -3 WHERE entity_id = %s$$, pg_temp.id('manga')), 'manga_chapter_count_ck');
SELECT pg_temp.t('negative LN volumes',    format($$UPDATE media.light_novel SET volume_count = -1 WHERE entity_id = %s$$, pg_temp.id('ln')), 'light_novel_volume_count_ck');
SELECT pg_temp.t('game local 1-4, no online', format($$UPDATE media.game SET local_players_min = 1, local_players_max = 4, online_players_min = 0, online_players_max = 0 WHERE entity_id = %s$$, pg_temp.id('game')), NULL);
SELECT pg_temp.t('game local min above max',  format($$UPDATE media.game SET local_players_min = 4, local_players_max = 1 WHERE entity_id = %s$$, pg_temp.id('game')), 'game_local_players_range_ck');
SELECT pg_temp.t('negative series episodes',  format($$UPDATE media.series SET episode_count = -2 WHERE entity_id = %s$$, pg_temp.id('series')), 'series_episode_count_ck');
SELECT pg_temp.t('movie 2 hours',             format($$UPDATE media.movie SET runtime_s = 7200 WHERE entity_id = %s$$, pg_temp.id('movie')), NULL);
SELECT pg_temp.t('zero movie runtime',        format($$UPDATE media.movie SET runtime_s = 0 WHERE entity_id = %s$$, pg_temp.id('movie')), 'seconds_ck');

\echo '--- schedules: PLANNING.md examples'
SELECT pg_temp.t('1 per 1 week',    pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',1,1,'week','2001','2001'$$), NULL);
SELECT pg_temp.t('1 per 2 weeks',   pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',1,2,'week','2002','2002'$$), NULL);
SELECT pg_temp.t('2 per 1 week',    pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',2,1,'week','2003','2003'$$), NULL);
SELECT pg_temp.t('1 per 1 month',   pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',1,1,'month','2004','2004'$$), NULL);
SELECT pg_temp.t('2 per 1 month',   pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',2,1,'month','2005','2005'$$), NULL);
SELECT pg_temp.t('1 per 2 months',  pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',1,2,'month','2006','2006'$$), NULL);
SELECT pg_temp.t('1 per 1 quarter', pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','volume',1,1,'quarter','2007','2007'$$), NULL);
SELECT pg_temp.t('1 per 1 year',    pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','volume',1,1,'year','2008','2008'$$), NULL);
SELECT pg_temp.t('3 per 2 months',  pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit,starts_on,ends_on', $$'regular','chapter',3,2,'month','2009','2009'$$), NULL);
SELECT pg_temp.eq('examples read back in order',
  (SELECT string_agg(item_count || '/' || period_count || '/' || period_unit, ' ' ORDER BY starts_on)
     FROM media.cadence_period WHERE entity_id = pg_temp.id('manga')),
  '1/1/week 1/2/week 2/1/week 1/1/month 2/1/month 1/2/month 1/1/quarter 1/1/year 3/2/month');

\echo '--- schedules: other shapes and refusals'
SELECT pg_temp.t('irregular chapters, no numbers',   pg_temp.cad('manga', 'schedule_type,item,starts_on', $$'irregular','chapter','2010'$$), NULL);
SELECT pg_temp.t('batch: 10 episodes at once',       pg_temp.cad('season', 'schedule_type,item,item_count,starts_on', $$'batch','episode',10,'2024-03-01'$$), NULL);
SELECT pg_temp.t('weekly, Thursday 01:28 Tokyo',     pg_temp.cad('anime', 'schedule_type,item,item_count,period_count,period_unit,weekday,local_time,time_zone', $$'regular','episode',1,1,'week',4,'01:28','Asia/Tokyo'$$), NULL);
SELECT pg_temp.t('irregular with numbers',           pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit', $$'irregular','chapter',1,1,'week'$$), 'cadence_shape_fk');
SELECT pg_temp.t('regular without numbers',          pg_temp.cad('manga', 'schedule_type,item', $$'regular','chapter'$$), 'cadence_shape_fk');
SELECT pg_temp.t('batch with a period',              pg_temp.cad('season', 'schedule_type,item,item_count,period_count,period_unit', $$'batch','episode',10,1,'week'$$), 'cadence_shape_fk');
SELECT pg_temp.t('period count without unit',        pg_temp.cad('manga', 'schedule_type,item,item_count,period_count', $$'regular','chapter',1,1$$), 'cadence_period_pair_ck');
SELECT pg_temp.t('schedule on a game',               pg_temp.cad('game', 'schedule_type,item', $$'irregular','episode'$$), 'cadence_item_allowed_fk');
SELECT pg_temp.t('chapters on an anime',             pg_temp.cad('anime', 'schedule_type,item', $$'irregular','chapter'$$), 'cadence_item_allowed_fk');
SELECT pg_temp.t('schedule on a volume',             pg_temp.cad('volume', 'schedule_type,item', $$'irregular','chapter'$$), 'cadence_item_allowed_fk');
SELECT pg_temp.t('weekday 8',                        pg_temp.cad('anime', 'schedule_type,item,weekday', $$'irregular','episode',8$$), 'cadence_weekday_ck');
SELECT pg_temp.t('time without zone',                pg_temp.cad('anime', 'schedule_type,item,local_time', $$'irregular','episode','20:00'$$), 'cadence_time_needs_zone_ck');
SELECT pg_temp.t('unknown time zone',                pg_temp.cad('anime', 'schedule_type,item,local_time,time_zone', $$'irregular','episode','20:00','Mars/Olympus'$$), 'is not a known time zone');
SELECT pg_temp.t('ends before starts',               pg_temp.cad('manga', 'schedule_type,item,starts_on,ends_on', $$'irregular','chapter','2012','2011-06'$$), 'cadence_dates_order_ck');
SELECT pg_temp.t('zero items',                       pg_temp.cad('manga', 'schedule_type,item,item_count,period_count,period_unit', $$'regular','chapter',0,1,'week'$$), 'cadence_item_count_ck');
SELECT pg_temp.t('kind does not match entity',       format($$INSERT INTO media.cadence_period (entity_id, kind, schedule_type, item) VALUES (%s, 'anime', 'irregular', 'episode')$$, pg_temp.id('manga')), 'cadence_entity_fk');
SELECT pg_temp.t('new schedule type is one row',     $$INSERT INTO media.schedule_type (code, labels, needs_count, needs_period) VALUES ('simulcast', core.label_en('Simulcast'), false, true)$$, NULL);
SELECT pg_temp.t('its declared shape is accepted',   pg_temp.cad('anime', 'schedule_type,item,period_count,period_unit', $$'simulcast','episode',1,'week'$$), NULL);
SELECT pg_temp.t('its declared shape is enforced',   pg_temp.cad('anime', 'schedule_type,item,item_count,period_count,period_unit', $$'simulcast','episode',1,1,'week'$$), 'cadence_shape_fk');

\echo '--- layer 1 still holds'
SELECT pg_temp.eq('every kind was creatable',
  (SELECT string_agg(k.name, ',') FROM core.entity_kind k WHERE NOT EXISTS (SELECT 1 FROM core.entity e WHERE e.kind = k.name)), NULL);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('ost'))))::text, pg_temp.id('ost')::text);
SELECT pg_temp.t('delete volume, then manga with schedules', format($$DELETE FROM core.entity WHERE id IN (%s); DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('volume'), pg_temp.id('manga')), NULL);
SELECT pg_temp.eq('schedules and work row went with it',
  (SELECT (SELECT count(*) FROM media.cadence_period WHERE entity_id = pg_temp.id('manga')) + (SELECT count(*) FROM media.work WHERE entity_id = pg_temp.id('manga')))::text, '0');
