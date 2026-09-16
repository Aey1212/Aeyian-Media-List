-- ============================================================================
-- AML migration 0006 — the Aey layer
--
-- PLANNING.md: scores run -50..+50 in the database and are shown as -10..+10
-- ("frontend score = backend score / 5"); the star display spans ten stars, five
-- negative and five positive, where "every 5 backend points equals half a star".
-- General Score is authoritative and holistic: it is never calculated or averaged
-- from subratings, and subratings carry no weights. Favourites are derived from
-- General Score, never flagged by hand.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

CREATE SCHEMA aey;   -- Aey's own layer: scores, subratings, takes, progress

-- ----------------------------------------------------------------------------
-- Which kinds can be rated
--
-- From PLANNING.md: "top characters, anime, games, episodes, seasons, volumes,
-- DLC, soundtracks" are ranked, and cut/edition pages carry "Aey General Score,
-- subratings and Aey's Take". Releases are not listed with any Aey data, and
-- people, companies, franchises, genres, tags, age ratings and platforms are not
-- rated either.
-- ----------------------------------------------------------------------------

ALTER TABLE core.entity_kind
  ADD COLUMN rateable boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT entity_kind_rateable_uq UNIQUE (name, rateable);

UPDATE core.entity_kind SET rateable = true
 WHERE name IN ('anime', 'manga', 'light_novel', 'game', 'series', 'movie',
                'season', 'episode', 'volume', 'dlc', 'cut', 'soundtrack',
                'character');

-- ----------------------------------------------------------------------------
-- The score itself
-- ----------------------------------------------------------------------------

CREATE DOMAIN core.score_50 AS smallint
  CONSTRAINT score_50_ck CHECK (VALUE BETWEEN -50 AND 50);

-- These take integer, not core.score_50: PostgreSQL does not implicitly convert a
-- plain integer to a domain over smallint, so domain parameters would make
-- aey.half_stars(32) fail to resolve. Stored scores still carry the domain.

-- The number shown to a reader: -10.0 .. +10.0
CREATE FUNCTION aey.score_shown(p_score integer) RETURNS numeric(3,1)
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT round(p_score / 5.0, 1)
$$;

-- Half-stars filled, -10 .. +10: every 5 points is half a star, and the
-- remainder is kept in the number rather than rounded into the stars.
CREATE FUNCTION aey.half_stars(p_score integer) RETURNS smallint
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT (sign(p_score) * trunc(abs(p_score) / 5))::smallint
$$;

-- ----------------------------------------------------------------------------
-- General Score
--
-- PLANNING.md: "General Score is authoritative and holistic" — nothing in this
-- schema derives it from subratings, and no view or trigger averages them.
-- There is no favourite flag either: rankings are ORDER BY general.
-- ----------------------------------------------------------------------------

CREATE TABLE aey.score (
  entity_id   bigint PRIMARY KEY,
  entity_kind text NOT NULL,
  rateable    boolean NOT NULL DEFAULT true CONSTRAINT score_rateable_ck CHECK (rateable),
  general     core.score_50 NOT NULL,
  rated_on    core.partial_date,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT score_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT score_rateable_fk FOREIGN KEY (entity_kind, rateable)
    REFERENCES core.entity_kind (name, rateable)
);
CREATE INDEX score_ranking_ix ON aey.score (entity_kind, general DESC);

-- ----------------------------------------------------------------------------
-- Subratings
--
-- PLANNING.md: "optional modular descriptive dimensions, also -50..+50", with
-- "no inherent weights", "no requirement to fill every suggested category" and
-- "medium/genre may suggest categories". Suggestions are advisory: nothing here
-- requires, weights or aggregates them.
--
-- The seeded categories are a starting set; every one is an editable row.
-- ----------------------------------------------------------------------------

CREATE TABLE aey.subrating_category (
  code       text PRIMARY KEY CONSTRAINT subrating_category_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO aey.subrating_category (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('story',      'Story',      10),
  ('characters', 'Characters', 20),
  ('pacing',     'Pacing',     30),
  ('art',        'Art',        40),
  ('animation',  'Animation',  50),
  ('music',      'Music',      60),
  ('gameplay',   'Gameplay',   70),
  ('world',      'World',      80)
) AS v (code, label, sort);

-- A category may be suggested for a medium or for a genre — exactly one of the two.
CREATE TABLE aey.subrating_suggestion (
  category   text NOT NULL CONSTRAINT subrating_suggestion_category_fk
             REFERENCES aey.subrating_category (code) ON UPDATE CASCADE ON DELETE CASCADE,
  kind       text CONSTRAINT subrating_suggestion_kind_fk
             REFERENCES core.entity_kind (name) ON UPDATE CASCADE,
  genre_id   bigint,
  genre_kind text NOT NULL DEFAULT 'genre' CONSTRAINT subrating_suggestion_genre_kind_ck CHECK (genre_kind = 'genre'),
  CONSTRAINT subrating_suggestion_one_target_ck CHECK (num_nonnulls(kind, genre_id) = 1),
  CONSTRAINT subrating_suggestion_uq UNIQUE NULLS NOT DISTINCT (category, kind, genre_id),
  CONSTRAINT subrating_suggestion_genre_fk FOREIGN KEY (genre_id, genre_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

CREATE TABLE aey.subrating (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  rateable    boolean NOT NULL DEFAULT true CONSTRAINT subrating_rateable_ck CHECK (rateable),
  category    text NOT NULL CONSTRAINT subrating_category_fk
              REFERENCES aey.subrating_category (code) ON UPDATE CASCADE,
  value       core.score_50 NOT NULL,
  PRIMARY KEY (entity_id, category),
  CONSTRAINT subrating_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT subrating_rateable_fk FOREIGN KEY (entity_kind, rateable)
    REFERENCES core.entity_kind (name, rateable)
);

-- ----------------------------------------------------------------------------
-- Aey's Take
--
-- PLANNING.md: "a short curator opinion displayed as a compact Aey's Take box.
-- It is intentionally not a full blog review." No length limit is imposed here;
-- keeping it short is the curator's call.
-- ----------------------------------------------------------------------------

CREATE TABLE aey.take (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  rateable    boolean NOT NULL DEFAULT true CONSTRAINT take_rateable_ck CHECK (rateable),
  lang        core.lang_tag NOT NULL,
  body        text NOT NULL CONSTRAINT take_body_ck CHECK (btrim(body) <> ''),
  written_on  core.partial_date,
  PRIMARY KEY (entity_id, lang),
  CONSTRAINT take_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT take_rateable_fk FOREIGN KEY (entity_kind, rateable)
    REFERENCES core.entity_kind (name, rateable)
);

-- ----------------------------------------------------------------------------
-- Progress and history
--
-- PLANNING.md, games: "Aey game data may include General Score, subratings, play
-- status, progress, dates, playthrough count, actual playtime, platforms played
-- on, and Aey's Take"; "Aey's actual playtime is personal data".
-- The document only details games, so the same shape is used for the six media
-- and for seasons — the units come from the existing item list (episode, chapter,
-- volume). The status list below is a starting set; every entry is an editable row.
-- ----------------------------------------------------------------------------

CREATE TABLE aey.status (
  code       text PRIMARY KEY CONSTRAINT status_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO aey.status (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('planning',    'Planning',    10),
  ('in_progress', 'In Progress', 20),
  ('on_hold',     'On Hold',     30),
  ('completed',   'Completed',   40),
  ('revisiting',  'Revisiting',  50),
  ('dropped',     'Dropped',     60)
) AS v (code, label, sort);

INSERT INTO core.attach_kind (system, kind)
SELECT 'progress', k FROM (VALUES
  ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie'), ('season')
) AS kinds (k);

CREATE TABLE aey.progress (
  entity_id       bigint PRIMARY KEY,
  entity_kind     text NOT NULL,
  system          text NOT NULL DEFAULT 'progress' CONSTRAINT progress_system_ck CHECK (system = 'progress'),
  status          text CONSTRAINT progress_status_fk REFERENCES aey.status (code) ON UPDATE CASCADE,
  progress_value  numeric(7,2) CONSTRAINT progress_value_ck CHECK (progress_value >= 0),
  progress_unit   text CONSTRAINT progress_unit_fk REFERENCES media.cadence_item (code) ON UPDATE CASCADE,
  started_on      core.partial_date,
  finished_on     core.partial_date,
  times_completed smallint CONSTRAINT progress_times_completed_ck CHECK (times_completed >= 0),
  time_spent_s    integer CONSTRAINT progress_time_spent_ck CHECK (time_spent_s > 0),
  note            text,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT progress_value_needs_unit_ck CHECK (progress_value IS NULL OR progress_unit IS NOT NULL),
  CONSTRAINT progress_dates_order_ck CHECK (core.partial_date_ordered(started_on, finished_on)),
  CONSTRAINT progress_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT progress_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);

-- "platforms played on"
CREATE TABLE aey.progress_platform (
  entity_id     bigint NOT NULL CONSTRAINT progress_platform_progress_fk
                REFERENCES aey.progress (entity_id) ON DELETE CASCADE,
  platform_id   bigint NOT NULL,
  platform_kind text NOT NULL DEFAULT 'platform' CONSTRAINT progress_platform_kind_ck CHECK (platform_kind = 'platform'),
  note          text,
  PRIMARY KEY (entity_id, platform_id),
  CONSTRAINT progress_platform_platform_fk FOREIGN KEY (platform_id, platform_kind)
    REFERENCES core.entity (id, kind) ON DELETE RESTRICT
);

COMMIT;
