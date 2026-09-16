-- ============================================================================
-- AML migration 0007 — external data
--
-- PLANNING.md: "External rating sources and metrics are modular. Records may
-- contain target, source, metric, score, scale, optional vote count, source URL
-- and recorded date. This supports MAL, AniList, IMDb, Rotten Tomatoes
-- critics/audience, Metacritic, Letterboxd, etc. without dedicated columns."
-- Also: "External estimated playtimes can be stored as external measurements",
-- and media, episodes, volumes, releases and soundtracks carry external links.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

CREATE SCHEMA ext;   -- data from outside sites: ratings, measurements, links

-- PLANNING.md gives external data to primary media and to the child entities
-- (episodes, volumes, releases, soundtracks ...: "many children share ...
-- external data"). People and companies are not listed; adding them is a row.
INSERT INTO core.attach_kind (system, kind)
SELECT 'external', k FROM (VALUES
  ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie'),
  ('season'), ('episode'), ('volume'), ('dlc'), ('release'), ('cut'), ('soundtrack')
) AS kinds (k);

-- ----------------------------------------------------------------------------
-- Sources, units and metrics
-- ----------------------------------------------------------------------------

CREATE TABLE ext.source (
  code       text PRIMARY KEY CONSTRAINT source_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  homepage   text CONSTRAINT source_homepage_ck CHECK (homepage ~ '^https?://\S+$'),
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE ext.unit (
  code       text PRIMARY KEY CONSTRAINT unit_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- A metric belongs to a source and carries its usual scale. Measurements with no
-- fixed scale (hours) leave the scale empty.
CREATE TABLE ext.metric (
  source     text NOT NULL CONSTRAINT metric_source_fk
             REFERENCES ext.source (code) ON UPDATE CASCADE ON DELETE CASCADE,
  code       text NOT NULL CONSTRAINT metric_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  unit       text NOT NULL CONSTRAINT metric_unit_fk REFERENCES ext.unit (code) ON UPDATE CASCADE,
  scale_min  numeric(10,3),
  scale_max  numeric(10,3),
  sort_order smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (source, code),
  CONSTRAINT metric_scale_pair_ck  CHECK ((scale_min IS NULL) = (scale_max IS NULL)),
  CONSTRAINT metric_scale_order_ck CHECK (scale_min < scale_max)
);

INSERT INTO ext.source (code, labels, homepage, sort_order)
SELECT code, core.label_en(label), homepage, sort FROM (VALUES
  ('mal',             'MyAnimeList',     'https://myanimelist.net',        10),
  ('anilist',         'AniList',         'https://anilist.co',             20),
  ('imdb',            'IMDb',            'https://www.imdb.com',           30),
  ('rotten_tomatoes', 'Rotten Tomatoes', 'https://www.rottentomatoes.com', 40),
  ('metacritic',      'Metacritic',      'https://www.metacritic.com',     50),
  ('letterboxd',      'Letterboxd',      'https://letterboxd.com',         60),
  ('howlongtobeat',   'HowLongToBeat',   'https://howlongtobeat.com',      70)
) AS v (code, label, homepage, sort);

INSERT INTO ext.unit (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('points',  'Points',  10),
  ('percent', 'Percent', 20),
  ('hours',   'Hours',   30)
) AS v (code, label, sort);

INSERT INTO ext.metric (source, code, labels, unit, scale_min, scale_max, sort_order)
SELECT source, code, core.label_en(label), unit, lo, hi, sort FROM (VALUES
  ('mal',             'score',         'Score',                   'points',  1,    10,   10),
  ('anilist',         'average_score', 'Average Score',           'percent', 0,    100,  10),
  ('imdb',            'rating',        'Rating',                  'points',  1,    10,   10),
  ('rotten_tomatoes', 'critics',       'Critics (Tomatometer)',   'percent', 0,    100,  10),
  ('rotten_tomatoes', 'audience',      'Audience (Popcornmeter)', 'percent', 0,    100,  20),
  ('metacritic',      'metascore',     'Metascore',               'points',  0,    100,  10),
  ('metacritic',      'user_score',    'User Score',              'points',  0,    10,   20),
  ('letterboxd',      'rating',        'Rating',                  'points',  0.5,  5,    10),
  ('howlongtobeat',   'main_story',    'Main Story',              'hours',   NULL, NULL, 10),
  ('howlongtobeat',   'main_extras',   'Main + Extras',           'hours',   NULL, NULL, 20),
  ('howlongtobeat',   'completionist', 'Completionist',           'hours',   NULL, NULL, 30)
) AS v (source, code, label, unit, lo, hi, sort);

-- ----------------------------------------------------------------------------
-- External ratings and measurements
--
-- One row per snapshot: a score for one target, source and metric on one date.
-- Keeping every date gives history; ext.rating_latest shows the newest.
-- The scale is stored on the row, as the document lists, and filled from the
-- metric when left empty on insert (a site can change its scale later).
-- Estimated playtimes are rows whose metric is measured in hours.
-- ----------------------------------------------------------------------------

CREATE TABLE ext.rating (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  system      text NOT NULL DEFAULT 'external' CONSTRAINT rating_system_ck CHECK (system = 'external'),
  source      text NOT NULL,
  metric      text NOT NULL,
  score       numeric(10,3) NOT NULL,
  scale_min   numeric(10,3),
  scale_max   numeric(10,3),
  vote_count  integer CONSTRAINT rating_vote_count_ck CHECK (vote_count >= 0),
  source_url  text CONSTRAINT rating_source_url_ck CHECK (source_url ~ '^https?://\S+$'),
  recorded_on date NOT NULL DEFAULT current_date,
  CONSTRAINT rating_metric_fk FOREIGN KEY (source, metric)
    REFERENCES ext.metric (source, code) ON UPDATE CASCADE,
  CONSTRAINT rating_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT rating_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind),
  CONSTRAINT rating_scale_pair_ck         CHECK ((scale_min IS NULL) = (scale_max IS NULL)),
  CONSTRAINT rating_scale_order_ck        CHECK (scale_min < scale_max),
  CONSTRAINT rating_score_in_scale_ck     CHECK (scale_min IS NULL OR score BETWEEN scale_min AND scale_max),
  CONSTRAINT rating_unscaled_not_negative_ck CHECK (scale_min IS NOT NULL OR score >= 0),
  CONSTRAINT rating_snapshot_uq UNIQUE (entity_id, source, metric, recorded_on)
);

-- Fill the scale from the metric on insert when none was given. Not on update:
-- a row whose metric changes keeps its scale unless the update sets a new one.
CREATE FUNCTION ext.trg_rating_fill_scale() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.scale_min IS NULL AND NEW.scale_max IS NULL THEN
    SELECT m.scale_min, m.scale_max INTO NEW.scale_min, NEW.scale_max
      FROM ext.metric m
     WHERE m.source = NEW.source AND m.code = NEW.metric;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER rating_fill_scale
  BEFORE INSERT ON ext.rating
  FOR EACH ROW EXECUTE FUNCTION ext.trg_rating_fill_scale();

-- The newest snapshot per target, source and metric.
CREATE VIEW ext.rating_latest AS
SELECT DISTINCT ON (entity_id, source, metric)
       id, entity_id, entity_kind, source, metric, score, scale_min, scale_max,
       vote_count, source_url, recorded_on
  FROM ext.rating
 ORDER BY entity_id, source, metric, recorded_on DESC;

-- ----------------------------------------------------------------------------
-- External links
--
-- PLANNING.md: primary media carry "external links", volumes "external links",
-- game releases "store/external links", soundtracks "external links".
-- A link may name a known source (a MAL page) or none (an official site, a store
-- not in the list); caption, language and region are optional.
-- ----------------------------------------------------------------------------

CREATE TABLE ext.link (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  system      text NOT NULL DEFAULT 'external' CONSTRAINT link_system_ck CHECK (system = 'external'),
  source      text CONSTRAINT link_source_fk REFERENCES ext.source (code) ON UPDATE CASCADE,
  url         text NOT NULL CONSTRAINT link_url_ck CHECK (url ~ '^https?://\S+$'),
  caption     core.labels,
  lang        core.lang_tag,       -- language of the linked page
  region      core.country_code,   -- e.g. a regional store
  sort_order  smallint NOT NULL DEFAULT 0,
  CONSTRAINT link_url_uq UNIQUE (entity_id, url),
  CONSTRAINT link_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT link_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX link_entity_ix ON ext.link (entity_id, sort_order);

COMMIT;
