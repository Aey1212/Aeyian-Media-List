-- ============================================================================
-- AML migration 0002 — primary media
--
-- Shared value types (labels, partial dates, seconds), media.work (fields every
-- medium shares, one row per media entity), type-specific fields for the six
-- media, and release schedules (cadence).
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Labels: multilingual names for option lists.
-- {"en": {"text": "TV", "native": false}, "ja": {"text": "テレビ", "native": true}}
-- At least one language, any language; at most one label is the native one.
-- ----------------------------------------------------------------------------

CREATE FUNCTION core.labels_valid(j jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE k text; v jsonb; natives int := 0;
BEGIN
  IF j IS NULL THEN RETURN true; END IF;
  IF jsonb_typeof(j) <> 'object' THEN RAISE EXCEPTION 'labels: must be an object keyed by language'; END IF;
  IF j = '{}'::jsonb THEN RAISE EXCEPTION 'labels: at least one language is required'; END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each(j) LOOP
    IF k !~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$' THEN
      RAISE EXCEPTION 'labels: "%" is not a language tag', k;
    END IF;
    IF jsonb_typeof(v) <> 'object' THEN
      RAISE EXCEPTION 'labels: "%" must be {"text": ..., "native": ...}', k;
    END IF;
    IF jsonb_typeof(v -> 'text') IS DISTINCT FROM 'string' OR btrim(v ->> 'text') = '' THEN
      RAISE EXCEPTION 'labels: "%" needs non-empty text', k;
    END IF;
    IF jsonb_typeof(v -> 'native') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'labels: "%" needs native true or false', k;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v)) <> 2 THEN
      RAISE EXCEPTION 'labels: "%" may only contain text and native', k;
    END IF;
    IF (v ->> 'native')::boolean THEN natives := natives + 1; END IF;
  END LOOP;
  IF natives > 1 THEN RAISE EXCEPTION 'labels: at most one language can be native'; END IF;
  RETURN true;
END $$;

CREATE DOMAIN core.labels AS jsonb
  CONSTRAINT labels_ck CHECK (core.labels_valid(VALUE));

-- Shorthand for seeding: one English, non-native label.
CREATE FUNCTION core.label_en(t text) RETURNS core.labels
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT jsonb_build_object('en', jsonb_build_object('text', t, 'native', false))::core.labels
$$;

-- ----------------------------------------------------------------------------
-- Partial dates: 'YYYY', 'YYYY-MM' or 'YYYY-MM-DD'; must be a real calendar date.
-- COLLATE "C" so comparison is plain character order.
-- ----------------------------------------------------------------------------

CREATE FUNCTION core.partial_date_valid(s text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE y int; m int; d int;
BEGIN
  IF s IS NULL THEN RETURN true; END IF;
  IF s !~ '^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$' THEN
    RAISE EXCEPTION 'partial_date: "%" is not YYYY, YYYY-MM or YYYY-MM-DD', s;
  END IF;
  y := substr(s, 1, 4)::int;
  IF y < 1 THEN RAISE EXCEPTION 'partial_date: year out of range in "%"', s; END IF;
  IF length(s) >= 7 THEN
    m := substr(s, 6, 2)::int;
    IF m NOT BETWEEN 1 AND 12 THEN RAISE EXCEPTION 'partial_date: month out of range in "%"', s; END IF;
  END IF;
  IF length(s) = 10 THEN
    d := substr(s, 9, 2)::int;
    BEGIN
      PERFORM make_date(y, m, d);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'partial_date: "%" is not a real calendar date', s;
    END;
  END IF;
  RETURN true;
END $$;

CREATE DOMAIN core.partial_date AS text COLLATE "C"
  CONSTRAINT partial_date_ck CHECK (core.partial_date_valid(VALUE));

-- End is not before start, compared at the coarser precision:
-- start '2006-07-13' with end '2006' is fine; end '2005-12' is not.
CREATE FUNCTION core.partial_date_ordered(starts core.partial_date, ends core.partial_date) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT starts IS NULL OR ends IS NULL OR ends >= left(starts, length(ends))
$$;

-- Durations in whole seconds.
CREATE DOMAIN core.seconds AS integer
  CONSTRAINT seconds_ck CHECK (VALUE > 0);

-- ----------------------------------------------------------------------------
-- Option lists. Each is code + labels + sort order; adding an option is a row.
-- ----------------------------------------------------------------------------

CREATE TABLE media.work_status (
  code       text PRIMARY KEY CONSTRAINT work_status_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- Which statuses each medium may use.
CREATE TABLE media.work_status_kind (
  status      text NOT NULL CONSTRAINT work_status_kind_status_fk
              REFERENCES media.work_status (code) ON UPDATE CASCADE ON DELETE CASCADE,
  kind        text NOT NULL,
  kind_family text NOT NULL DEFAULT 'media'
              CONSTRAINT work_status_kind_family_ck CHECK (kind_family = 'media'),
  PRIMARY KEY (status, kind),
  CONSTRAINT work_status_kind_kind_fk FOREIGN KEY (kind, kind_family)
    REFERENCES core.entity_kind (name, family) ON UPDATE CASCADE
);

CREATE TABLE media.source_type (
  code       text PRIMARY KEY CONSTRAINT source_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE media.anime_format (
  code       text PRIMARY KEY CONSTRAINT anime_format_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO media.work_status (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('upcoming',     'Upcoming',     10),
  ('announced',    'Announced',    15),
  ('airing',       'Airing',       20),
  ('publishing',   'Publishing',   25),
  ('early_access', 'Early Access', 30),
  ('released',     'Released',     40),
  ('finished',     'Finished',     50),
  ('hiatus',       'On Hiatus',    60),
  ('cancelled',    'Cancelled',    70)
) AS v (code, label, sort);

INSERT INTO media.work_status_kind (status, kind) VALUES
  ('upcoming',     'anime'), ('upcoming',   'series'), ('upcoming',  'manga'), ('upcoming', 'light_novel'),
  ('airing',       'anime'), ('airing',     'series'),
  ('publishing',   'manga'), ('publishing', 'light_novel'),
  ('finished',     'anime'), ('finished',   'series'), ('finished',  'manga'), ('finished', 'light_novel'),
  ('hiatus',       'anime'), ('hiatus',     'series'), ('hiatus',    'manga'), ('hiatus',   'light_novel'),
  ('announced',    'game'),  ('announced',  'movie'),
  ('early_access', 'game'),
  ('released',     'game'),  ('released',   'movie'),
  ('cancelled',    'anime'), ('cancelled',  'series'), ('cancelled', 'manga'), ('cancelled', 'light_novel'),
  ('cancelled',    'game'),  ('cancelled',  'movie');

INSERT INTO media.source_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('original',     'Original',     10),
  ('manga',        'Manga',        20),
  ('web_manga',    'Web Manga',    25),
  ('light_novel',  'Light Novel',  30),
  ('web_novel',    'Web Novel',    35),
  ('novel',        'Novel',        40),
  ('visual_novel', 'Visual Novel', 50),
  ('game',         'Game',         60),
  ('anime',        'Anime',        70),
  ('series',       'Series',       80),
  ('movie',        'Movie',        90),
  ('other',        'Other',       100)
) AS v (code, label, sort);

INSERT INTO media.anime_format (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('tv',          'TV',          10),
  ('ova',         'OVA',         20),
  ('ona',         'ONA',         30),
  ('movie',       'Movie',       40),
  ('special',     'Special',     50),
  ('music_video', 'Music Video', 60),
  ('short',       'Short',       70)
) AS v (code, label, sort);

-- ----------------------------------------------------------------------------
-- media.work — fields every medium shares. One row per media entity;
-- kind says which medium. Created automatically with the entity.
-- ----------------------------------------------------------------------------

CREATE TABLE media.work (
  entity_id   bigint PRIMARY KEY,
  kind        text NOT NULL,
  family      text NOT NULL DEFAULT 'media' CONSTRAINT work_family_ck CHECK (family = 'media'),
  status      text,                   -- NULL = not set yet
  start_date  core.partial_date,      -- aired / published / released
  end_date    core.partial_date,
  source_type text CONSTRAINT work_source_type_fk REFERENCES media.source_type (code) ON UPDATE CASCADE,
  CONSTRAINT work_entity_fk FOREIGN KEY (entity_id, kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT work_kind_family_fk FOREIGN KEY (kind, family)
    REFERENCES core.entity_kind (name, family),
  CONSTRAINT work_status_allowed_fk FOREIGN KEY (status, kind)
    REFERENCES media.work_status_kind (status, kind),
  CONSTRAINT work_dates_order_ck CHECK (core.partial_date_ordered(start_date, end_date))
);
CREATE INDEX work_status_ix ON media.work (kind, status);

CREATE FUNCTION media.create_work_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO media.work (entity_id, kind) VALUES (NEW.id, NEW.kind);
  RETURN NULL;
END $$;

CREATE TRIGGER entity_media_work
  AFTER INSERT ON core.entity
  FOR EACH ROW WHEN (NEW.family = 'media')
  EXECUTE FUNCTION media.create_work_row();

-- Media entities that existed before this migration.
INSERT INTO media.work (entity_id, kind)
SELECT id, kind FROM core.entity WHERE family = 'media'
ON CONFLICT (entity_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Type-specific fields.
-- Counts are the declared totals, not counted from child pages (not every
-- episode or volume will have a page). NULL = unknown.
-- ----------------------------------------------------------------------------

ALTER TABLE media.anime
  ADD COLUMN format            text CONSTRAINT anime_format_fk REFERENCES media.anime_format (code) ON UPDATE CASCADE,
  ADD COLUMN episode_count     integer CONSTRAINT anime_episode_count_ck CHECK (episode_count >= 0),
  ADD COLUMN typical_runtime_s core.seconds;

ALTER TABLE media.manga
  ADD COLUMN volume_count  integer CONSTRAINT manga_volume_count_ck  CHECK (volume_count >= 0),
  ADD COLUMN chapter_count integer CONSTRAINT manga_chapter_count_ck CHECK (chapter_count >= 0);

ALTER TABLE media.light_novel
  ADD COLUMN volume_count integer CONSTRAINT light_novel_volume_count_ck CHECK (volume_count >= 0);

-- Player counts: 0 = mode not supported.
ALTER TABLE media.game
  ADD COLUMN local_players_min  smallint CONSTRAINT game_local_players_min_ck  CHECK (local_players_min >= 0),
  ADD COLUMN local_players_max  smallint CONSTRAINT game_local_players_max_ck  CHECK (local_players_max >= 0),
  ADD COLUMN online_players_min smallint CONSTRAINT game_online_players_min_ck CHECK (online_players_min >= 0),
  ADD COLUMN online_players_max smallint CONSTRAINT game_online_players_max_ck CHECK (online_players_max >= 0),
  ADD CONSTRAINT game_local_players_range_ck  CHECK (local_players_min <= local_players_max),
  ADD CONSTRAINT game_online_players_range_ck CHECK (online_players_min <= online_players_max);

ALTER TABLE media.series
  ADD COLUMN episode_count     integer CONSTRAINT series_episode_count_ck CHECK (episode_count >= 0),
  ADD COLUMN typical_runtime_s core.seconds;

ALTER TABLE media.movie
  ADD COLUMN runtime_s core.seconds;

-- ----------------------------------------------------------------------------
-- Release schedules (cadence)
--
-- A regular schedule is item_count per period_count period_unit:
--   1 per 1 week = Weekly, 1 per 2 weeks, 2 per 1 week, 3 per 2 months ...
-- Irregular has no numbers. Batch has a count (released at once) and no period.
-- Each schedule type declares which numbers it needs, so a new type is a row.
-- Periods have their own date range because schedules change over time.
-- Turning a schedule into words ("Weekly") is the backend's job, per language.
-- ----------------------------------------------------------------------------

-- IMMUTABLE for use in CHECK; depends on the server's time zone database.
CREATE FUNCTION core.time_zone_valid(tz text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF tz IS NULL THEN RETURN true; END IF;
  BEGIN
    PERFORM timestamp '2000-01-01 00:00' AT TIME ZONE tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION 'time_zone: "%" is not a known time zone', tz;
  END;
  RETURN true;
END $$;

CREATE TABLE media.schedule_type (
  code         text PRIMARY KEY CONSTRAINT schedule_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels       core.labels NOT NULL,
  needs_count  boolean NOT NULL,   -- item_count required (true) or forbidden (false)
  needs_period boolean NOT NULL,   -- period_count + period_unit required (true) or forbidden (false)
  sort_order   smallint NOT NULL DEFAULT 0,
  CONSTRAINT schedule_type_shape_uq UNIQUE (code, needs_count, needs_period)
);

CREATE TABLE media.cadence_item (
  code       text PRIMARY KEY CONSTRAINT cadence_item_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- Which kinds may have schedules, and for which items.
CREATE TABLE media.cadence_item_kind (
  item text NOT NULL CONSTRAINT cadence_item_kind_item_fk
       REFERENCES media.cadence_item (code) ON UPDATE CASCADE ON DELETE CASCADE,
  kind text NOT NULL CONSTRAINT cadence_item_kind_kind_fk
       REFERENCES core.entity_kind (name) ON UPDATE CASCADE,
  PRIMARY KEY (item, kind)
);

CREATE TABLE media.period_unit (
  code       text PRIMARY KEY CONSTRAINT period_unit_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO media.schedule_type (code, labels, needs_count, needs_period, sort_order) VALUES
  ('regular',   core.label_en('Regular'),   true,  true,  10),
  ('irregular', core.label_en('Irregular'), false, false, 20),
  ('batch',     core.label_en('Batch'),     true,  false, 30);

INSERT INTO media.cadence_item (code, labels, sort_order) VALUES
  ('episode', core.label_en('Episode'), 10),
  ('chapter', core.label_en('Chapter'), 20),
  ('volume',  core.label_en('Volume'),  30);

INSERT INTO media.cadence_item_kind (item, kind) VALUES
  ('episode', 'anime'), ('episode', 'series'), ('episode', 'season'),
  ('chapter', 'manga'), ('chapter', 'light_novel'),
  ('volume',  'manga'), ('volume',  'light_novel');

INSERT INTO media.period_unit (code, labels, sort_order) VALUES
  ('day',     core.label_en('Day'),     10),
  ('week',    core.label_en('Week'),    20),
  ('month',   core.label_en('Month'),   30),
  ('quarter', core.label_en('Quarter'), 40),
  ('year',    core.label_en('Year'),    50);

CREATE TABLE media.cadence_period (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id     bigint NOT NULL,
  kind          text NOT NULL,
  schedule_type text NOT NULL,
  item          text NOT NULL,
  item_count    integer CONSTRAINT cadence_item_count_ck   CHECK (item_count > 0),
  period_count  integer CONSTRAINT cadence_period_count_ck CHECK (period_count > 0),
  period_unit   text CONSTRAINT cadence_period_unit_fk REFERENCES media.period_unit (code) ON UPDATE CASCADE,
  starts_on     core.partial_date,
  ends_on       core.partial_date,
  weekday       smallint CONSTRAINT cadence_weekday_ck CHECK (weekday BETWEEN 1 AND 7),  -- ISO 8601: 1 = Monday
  local_time    time,
  time_zone     text CONSTRAINT cadence_time_zone_ck CHECK (core.time_zone_valid(time_zone)),  -- IANA name, e.g. Asia/Tokyo
  note          text,
  has_count     boolean GENERATED ALWAYS AS (item_count IS NOT NULL) STORED,
  has_period    boolean GENERATED ALWAYS AS (period_count IS NOT NULL) STORED,
  CONSTRAINT cadence_entity_fk FOREIGN KEY (entity_id, kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT cadence_item_allowed_fk FOREIGN KEY (item, kind)
    REFERENCES media.cadence_item_kind (item, kind),
  CONSTRAINT cadence_shape_fk FOREIGN KEY (schedule_type, has_count, has_period)
    REFERENCES media.schedule_type (code, needs_count, needs_period),
  CONSTRAINT cadence_period_pair_ck      CHECK ((period_count IS NULL) = (period_unit IS NULL)),
  CONSTRAINT cadence_dates_order_ck      CHECK (core.partial_date_ordered(starts_on, ends_on)),
  CONSTRAINT cadence_time_needs_zone_ck  CHECK (local_time IS NULL OR time_zone IS NOT NULL)
);
CREATE INDEX cadence_period_entity_ix ON media.cadence_period (entity_id);

COMMIT;
