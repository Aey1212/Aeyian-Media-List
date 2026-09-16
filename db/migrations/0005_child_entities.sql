-- ============================================================================
-- AML migration 0005 — child entities and platforms
--
-- Fields for Season, Episode, Volume, DLC, Release, Cut and Soundtrack, the
-- tracks of a soundtrack, themes linked to episodes, and platforms as entities
-- (Platform Family -> Platform). Per PLANNING.md's per-medium sections.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Platforms
--
-- PLANNING.md: "Platforms are reusable and may have hierarchical/multi-parent
-- organization (PC > Windows/Linux/macOS; PlayStation family, etc.)".
-- A platform sits under its family (PlayStation -> PS2), gets its own page, and
-- is not rateable (the rateable flag per kind arrives in layer 6).
-- ----------------------------------------------------------------------------

INSERT INTO core.entity_kind (name, code, family, scope, seq_width) VALUES
  ('platform_family', '26', 'world', 'global', 2),
  ('platform',        '18', 'child', 'parent', 2);

INSERT INTO core.entity_kind_parent (child_kind, parent_kind) VALUES
  ('platform', 'platform_family');

CREATE TABLE world.platform_family (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'platform_family' CONSTRAINT platform_family_kind_ck CHECK (kind = 'platform_family'),
  CONSTRAINT platform_family_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

CREATE TABLE child.platform (
  entity_id    bigint PRIMARY KEY,
  kind         text NOT NULL DEFAULT 'platform' CONSTRAINT platform_kind_ck CHECK (kind = 'platform'),
  released_on  core.partial_date,
  discontinued core.partial_date,
  CONSTRAINT platform_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT platform_dates_order_ck CHECK (core.partial_date_ordered(released_on, discontinued))
);

-- ----------------------------------------------------------------------------
-- Option lists for child entities
-- ----------------------------------------------------------------------------

-- PLANNING.md: "DLC gets proper pages and modular DLC categories rather than a fixed enum."
CREATE TABLE media.dlc_category (
  code       text PRIMARY KEY CONSTRAINT dlc_category_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- PLANNING.md: "Reusable release types can include Theatrical, Festival, Television,
-- Streaming, Home Video, Limited Theatrical, Premiere, etc."
CREATE TABLE media.release_type (
  code       text PRIMARY KEY CONSTRAINT release_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- "physical/digital information" on game releases
CREATE TABLE media.distribution (
  code       text PRIMARY KEY CONSTRAINT distribution_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- PLANNING.md: "Theatrical Cut, Director's Cut, Extended Cut, Unrated Cut, Restored Version, etc."
CREATE TABLE media.cut_type (
  code       text PRIMARY KEY CONSTRAINT cut_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

-- PLANNING.md: "Theme/opening/ending/insert songs can be linked contextually to
-- anime/series episodes where appropriate."
CREATE TABLE media.theme_type (
  code       text PRIMARY KEY CONSTRAINT theme_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO media.dlc_category (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('expansion',   'Expansion',   10),
  ('story',       'Story',       20),
  ('character',   'Character',   30),
  ('cosmetic',    'Cosmetic',    40),
  ('season_pass', 'Season Pass', 50),
  ('other',       'Other',       60)
) AS v (code, label, sort);

INSERT INTO media.release_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('theatrical',         'Theatrical',         10),
  ('limited_theatrical', 'Limited Theatrical', 20),
  ('premiere',           'Premiere',           30),
  ('festival',           'Festival',           40),
  ('television',         'Television',         50),
  ('streaming',          'Streaming',          60),
  ('home_video',         'Home Video',         70),
  ('retail',             'Retail',             80),
  ('store',              'Store',              90)
) AS v (code, label, sort);

INSERT INTO media.distribution (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('physical', 'Physical', 10),
  ('digital',  'Digital',  20)
) AS v (code, label, sort);

INSERT INTO media.cut_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('theatrical', 'Theatrical Cut', 10),
  ('directors',  'Director''s Cut', 20),
  ('extended',   'Extended Cut',   30),
  ('unrated',    'Unrated Cut',    40),
  ('restored',   'Restored Version', 50)
) AS v (code, label, sort);

INSERT INTO media.theme_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('opening', 'Opening',      10),
  ('ending',  'Ending',       20),
  ('insert',  'Insert Song',  30),
  ('theme',   'Theme Song',   40)
) AS v (code, label, sort);

-- Soundtracks list "composers, performers, label" (PLANNING.md), so those two roles join the lists.
INSERT INTO core.staff_role (code, labels, sort_order) VALUES ('performer', core.label_en('Performer'), 50);
INSERT INTO core.company_role (code, labels, sort_order) VALUES ('label', core.label_en('Label'), 110);

-- ----------------------------------------------------------------------------
-- Seasons and episodes
--
-- PLANNING.md: a season page has "number/display name, optional title, poster,
-- synopsis, dates" and "Non-numeric/special seasons must work" — so the number may
-- be empty and a display name ("Specials", "Cour 2") can stand on its own.
-- Titles, posters and synopses come from layer 3; staff and cast from layer 4.
--
-- No "must have a number or a name" constraint: core.create_entity inserts the type
-- row empty and fields are filled afterwards, so every child type table has to accept
-- an all-empty row. A season that is about to go public is covered by the layer 3 rule
-- that a published entity needs a title.
-- ----------------------------------------------------------------------------

ALTER TABLE child.season
  ADD COLUMN number       smallint CONSTRAINT season_number_ck CHECK (number >= 0),
  ADD COLUMN display_name text CONSTRAINT season_display_name_ck CHECK (btrim(display_name) <> ''),
  ADD COLUMN started_on   core.partial_date,
  ADD COLUMN ended_on     core.partial_date,
  ADD CONSTRAINT season_dates_order_ck CHECK (core.partial_date_ordered(started_on, ended_on));

-- Episode numbers allow halves (12.5 specials). "source_coverage" is the
-- "source/adaptation coverage" the document asks for, e.g. "adapts chapters 1-8".
ALTER TABLE child.episode
  ADD COLUMN number_in_season numeric(7,2) CONSTRAINT episode_number_in_season_ck CHECK (number_in_season >= 0),
  ADD COLUMN number_overall   numeric(7,2) CONSTRAINT episode_number_overall_ck   CHECK (number_overall >= 0),
  ADD COLUMN aired_on         core.partial_date,
  ADD COLUMN runtime_s        core.seconds,
  ADD COLUMN source_coverage  text;

-- ----------------------------------------------------------------------------
-- Volumes
--
-- PLANNING.md: "number, optional title, covers, release dates, ISBNs, publishers,
-- page count, chapter range/content information". Titles and covers come from
-- layer 3, publishers are company credits (layer 4). Volume numbers allow halves
-- (6.5 volumes exist), and a volume can carry several ISBNs (editions).
-- ----------------------------------------------------------------------------

ALTER TABLE child.volume
  ADD COLUMN number       numeric(7,2) CONSTRAINT volume_number_ck CHECK (number >= 0),
  ADD COLUMN released_on  core.partial_date,
  ADD COLUMN page_count   integer CONSTRAINT volume_page_count_ck CHECK (page_count > 0),
  ADD COLUMN chapter_from numeric(7,2) CONSTRAINT volume_chapter_from_ck CHECK (chapter_from >= 0),
  ADD COLUMN chapter_to   numeric(7,2) CONSTRAINT volume_chapter_to_ck   CHECK (chapter_to >= 0),
  ADD COLUMN contents     text,   -- free text, e.g. "chapters 1-8 and a bonus story"
  ADD CONSTRAINT volume_chapter_range_ck
    CHECK (chapter_from IS NULL OR chapter_to IS NULL OR chapter_from <= chapter_to);

-- ISBN-10 or ISBN-13, digits only (hyphens are a display matter).
CREATE TABLE child.volume_isbn (
  volume_id bigint NOT NULL CONSTRAINT volume_isbn_volume_fk
            REFERENCES child.volume (entity_id) ON DELETE CASCADE,
  isbn      text NOT NULL CONSTRAINT volume_isbn_format_ck CHECK (isbn ~ '^(97[89])?[0-9]{9}[0-9X]$'),
  note      text,   -- e.g. "limited edition"
  PRIMARY KEY (volume_id, isbn)
);

-- ----------------------------------------------------------------------------
-- DLC and cuts
--
-- PLANNING.md: DLC has "modular DLC categories rather than a fixed enum";
-- a cut has "title, type, runtime, release data, description, changed/additional
-- content" (title and description come from layer 3).
-- ----------------------------------------------------------------------------

ALTER TABLE child.dlc
  ADD COLUMN category    text CONSTRAINT dlc_category_fk REFERENCES media.dlc_category (code) ON UPDATE CASCADE,
  ADD COLUMN released_on core.partial_date;

ALTER TABLE child.cut
  ADD COLUMN cut_type  text CONSTRAINT cut_cut_type_fk REFERENCES media.cut_type (code) ON UPDATE CASCADE,
  ADD COLUMN runtime_s core.seconds,
  ADD COLUMN changes   text;   -- changed or additional content

-- ----------------------------------------------------------------------------
-- Releases
--
-- PLANNING.md, games: "platform, region, release date, publisher, languages, age
-- ratings, store/external links and physical/digital information".
-- Movies: "region, date, modular release type, distributor, languages and age
-- ratings". Publishers and distributors are company credits (layer 4), age ratings
-- attach from layer 3, store links are layer 7.
-- ----------------------------------------------------------------------------

ALTER TABLE child.release
  ADD COLUMN release_type  text CONSTRAINT release_release_type_fk REFERENCES media.release_type (code) ON UPDATE CASCADE,
  ADD COLUMN region        core.country_code,
  ADD COLUMN released_on   core.partial_date,
  ADD COLUMN platform_id   bigint,   -- game releases
  ADD COLUMN platform_kind text NOT NULL DEFAULT 'platform'
             CONSTRAINT release_platform_kind_ck CHECK (platform_kind = 'platform'),
  ADD COLUMN distribution  text CONSTRAINT release_distribution_fk REFERENCES media.distribution (code) ON UPDATE CASCADE,
  -- a platform still used by a release cannot be deleted
  ADD CONSTRAINT release_platform_fk FOREIGN KEY (platform_id, platform_kind)
    REFERENCES core.entity (id, kind) ON DELETE RESTRICT;
CREATE INDEX release_platform_ix ON child.release (platform_id);

CREATE TABLE child.release_language (
  release_id bigint NOT NULL CONSTRAINT release_language_release_fk
             REFERENCES child.release (entity_id) ON DELETE CASCADE,
  lang       core.lang_tag NOT NULL,
  note       text,   -- e.g. "subtitles only"
  sort_order smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (release_id, lang)
);

-- ----------------------------------------------------------------------------
-- Soundtracks, their tracks, and themes on episodes
--
-- PLANNING.md: a soundtrack has "release dates, composers, performers, label,
-- tracks, runtime"; "Individual tracks do not initially require independent pages";
-- "Theme/opening/ending/insert songs can be linked contextually to anime/series
-- episodes". Composers, performers and label are credits (layer 4).
-- ----------------------------------------------------------------------------

ALTER TABLE child.soundtrack
  ADD COLUMN released_on core.partial_date,
  ADD COLUMN runtime_s   core.seconds;   -- total runtime

-- Tracks are rows, not entities: no address, no page of their own.
-- Track titles use the multilingual label type, so Japanese and romaji both fit.
CREATE TABLE child.soundtrack_track (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  soundtrack_id bigint NOT NULL CONSTRAINT soundtrack_track_soundtrack_fk
                REFERENCES child.soundtrack (entity_id) ON DELETE CASCADE,
  disc_no       smallint CONSTRAINT soundtrack_track_disc_ck CHECK (disc_no > 0),
  track_no      smallint CONSTRAINT soundtrack_track_no_ck CHECK (track_no > 0),
  titles        core.labels NOT NULL,
  runtime_s     core.seconds,
  note          text,
  CONSTRAINT soundtrack_track_uq UNIQUE NULLS NOT DISTINCT (soundtrack_id, disc_no, track_no)
);

CREATE TABLE child.episode_theme (
  episode_id   bigint NOT NULL,
  episode_kind text NOT NULL DEFAULT 'episode' CONSTRAINT episode_theme_episode_kind_ck CHECK (episode_kind = 'episode'),
  track_id     bigint NOT NULL CONSTRAINT episode_theme_track_fk
               REFERENCES child.soundtrack_track (id) ON DELETE CASCADE,
  theme_type   text NOT NULL CONSTRAINT episode_theme_type_fk
               REFERENCES media.theme_type (code) ON UPDATE CASCADE,
  note         text,
  PRIMARY KEY (episode_id, track_id, theme_type),
  CONSTRAINT episode_theme_episode_fk FOREIGN KEY (episode_id, episode_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE INDEX episode_theme_track_ix ON child.episode_theme (track_id);

COMMIT;
