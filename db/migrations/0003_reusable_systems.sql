-- ============================================================================
-- AML migration 0003 — reusable systems
--
-- Titles and texts for every entity, genres and tags (multi-parent trees),
-- age rating systems and ratings, images, role lists used by credits (layer 4),
-- original languages and countries of origin.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Option lists (code + labels + sort order; adding an option is a row)
-- ----------------------------------------------------------------------------

CREATE TABLE core.title_type (
  code       text PRIMARY KEY CONSTRAINT title_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.text_type (
  code       text PRIMARY KEY CONSTRAINT text_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.image_type (
  code       text PRIMARY KEY CONSTRAINT image_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.staff_role (
  code       text PRIMARY KEY CONSTRAINT staff_role_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.company_role (
  code       text PRIMARY KEY CONSTRAINT company_role_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.appearance_role (
  code       text PRIMARY KEY CONSTRAINT appearance_role_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

CREATE TABLE core.performance_type (
  code       text PRIMARY KEY CONSTRAINT performance_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  labels     core.labels NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0
);

INSERT INTO core.title_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('full',        'Full',        10),
  ('short',       'Short',       20),
  ('alternative', 'Alternative', 30)
) AS v (code, label, sort);

INSERT INTO core.text_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('synopsis',    'Synopsis',    10),
  ('description', 'Description', 20)
) AS v (code, label, sort);

INSERT INTO core.image_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('cover',         'Cover',          10),
  ('poster',        'Poster',         20),
  ('banner',        'Banner',         30),
  ('backdrop',      'Backdrop',       40),
  ('box_art',       'Box Art',        50),
  ('logo',          'Logo',           60),
  ('thumbnail',     'Thumbnail',      70),
  ('volume_cover',  'Volume Cover',   80),
  ('season_poster', 'Season Poster',  90),
  ('portrait',      'Portrait',      100),
  ('icon',          'Icon',          110)
) AS v (code, label, sort);

INSERT INTO core.staff_role (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('director',           'Director',           10),
  ('writer',             'Writer',             20),
  ('composer',           'Composer',           30),
  ('character_designer', 'Character Designer', 40)
) AS v (code, label, sort);

INSERT INTO core.company_role (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('animation_studio',       'Animation Studio',       10),
  ('developer',              'Developer',              20),
  ('publisher',              'Publisher',              30),
  ('production_company',     'Production Company',     40),
  ('distributor',            'Distributor',            50),
  ('licensor',               'Licensor',               60),
  ('broadcaster',            'Broadcaster',            70),
  ('original_network',       'Original Network',       80),
  ('localization_publisher', 'Localization Publisher', 90),
  ('imprint',                'Imprint',               100)
) AS v (code, label, sort);

INSERT INTO core.appearance_role (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('protagonist', 'Protagonist', 10),
  ('main',        'Main',        20),
  ('supporting',  'Supporting',  30),
  ('antagonist',  'Antagonist',  40),
  ('playable',    'Playable',    50),
  ('boss',        'Boss',        60),
  ('guest',       'Guest',       70)
) AS v (code, label, sort);

INSERT INTO core.performance_type (code, labels, sort_order)
SELECT code, core.label_en(label), sort FROM (VALUES
  ('voice',          'Voice',          10),
  ('live_action',    'Live Action',    20),
  ('motion_capture', 'Motion Capture', 30)
) AS v (code, label, sort);

-- ----------------------------------------------------------------------------
-- Titles and texts — for every entity
-- ----------------------------------------------------------------------------

-- Language tag: en, ja, tr, ja-Latn (romaji), pt-BR ...
CREATE DOMAIN core.lang_tag AS text
  CONSTRAINT lang_tag_ck CHECK (VALUE ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE core.title (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id    bigint NOT NULL CONSTRAINT title_entity_fk REFERENCES core.entity (id) ON DELETE CASCADE,
  lang         core.lang_tag NOT NULL,
  title_type   text NOT NULL CONSTRAINT title_type_fk REFERENCES core.title_type (code) ON UPDATE CASCADE,
  text         text NOT NULL CONSTRAINT title_text_ck CHECK (btrim(text) <> ''),
  native       boolean NOT NULL DEFAULT false,   -- the title in the work's original language
  preferred    boolean NOT NULL DEFAULT false,   -- shown for this language and type when there are several
  romanizes_id bigint,                           -- a romanized title points to the title it spells out
  sort_order   smallint NOT NULL DEFAULT 0,
  CONSTRAINT title_id_entity_type_uq UNIQUE (id, entity_id, title_type),
  CONSTRAINT title_text_uq UNIQUE (entity_id, lang, title_type, text),
  -- same entity and same type as the title it romanizes
  CONSTRAINT title_romanizes_fk FOREIGN KEY (romanizes_id, entity_id, title_type)
    REFERENCES core.title (id, entity_id, title_type),
  CONSTRAINT title_romanizes_self_ck         CHECK (romanizes_id <> id),
  CONSTRAINT title_romanization_latin_ck     CHECK (romanizes_id IS NULL OR lang ~ '-Latn(-|$)'),
  CONSTRAINT title_romanization_not_native_ck CHECK (NOT (native AND romanizes_id IS NOT NULL))
);
CREATE UNIQUE INDEX title_native_uq    ON core.title (entity_id, title_type)       WHERE native;
CREATE UNIQUE INDEX title_preferred_uq ON core.title (entity_id, lang, title_type) WHERE preferred;
CREATE INDEX title_entity_ix    ON core.title (entity_id);
CREATE INDEX title_text_trgm_ix ON core.title USING gin (text gin_trgm_ops);

CREATE TABLE core.entity_text (
  entity_id bigint NOT NULL CONSTRAINT entity_text_entity_fk REFERENCES core.entity (id) ON DELETE CASCADE,
  text_type text NOT NULL CONSTRAINT entity_text_type_fk REFERENCES core.text_type (code) ON UPDATE CASCADE,
  lang      core.lang_tag NOT NULL,
  body      text NOT NULL CONSTRAINT entity_text_body_ck CHECK (btrim(body) <> ''),
  PRIMARY KEY (entity_id, text_type, lang)
);

-- A published entity must have at least one title.
-- Checked at commit, so one transaction can create, title and publish an entity,
-- or replace a title, in any order.
CREATE FUNCTION core.check_published_has_title(p_entity bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.entity e WHERE e.id = p_entity AND e.published_at IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = p_entity) THEN
    RAISE EXCEPTION 'publish: published entity % has no title', p_entity USING ERRCODE = 'check_violation';
  END IF;
END $$;

CREATE FUNCTION core.trg_entity_publish_needs_title() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM core.check_published_has_title(NEW.id);
  RETURN NULL;
END $$;

CREATE FUNCTION core.trg_title_removal_keeps_one() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM core.check_published_has_title(OLD.entity_id);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER entity_publish_needs_title
  AFTER INSERT OR UPDATE OF published_at ON core.entity
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (NEW.published_at IS NOT NULL)
  EXECUTE FUNCTION core.trg_entity_publish_needs_title();

CREATE CONSTRAINT TRIGGER title_removal_keeps_one
  AFTER DELETE OR UPDATE OF entity_id ON core.title
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION core.trg_title_removal_keeps_one();

-- ----------------------------------------------------------------------------
-- New kinds: genre, tag, age rating system (world) and age rating (child of its system)
-- ----------------------------------------------------------------------------

INSERT INTO core.entity_kind (name, code, family, scope, seq_width) VALUES
  ('genre',             '27', 'world', 'global', 3),
  ('tag',               '28', 'world', 'global', 3),
  ('age_rating_system', '29', 'world', 'global', 2),
  ('age_rating',        '19', 'child', 'parent', 2);

INSERT INTO core.entity_kind_parent (child_kind, parent_kind) VALUES
  ('age_rating', 'age_rating_system');

CREATE TABLE world.genre (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'genre' CONSTRAINT genre_kind_ck CHECK (kind = 'genre'),
  CONSTRAINT genre_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE world.tag (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'tag' CONSTRAINT tag_kind_ck CHECK (kind = 'tag'),
  CONSTRAINT tag_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE world.age_rating_system (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'age_rating_system' CONSTRAINT age_rating_system_kind_ck CHECK (kind = 'age_rating_system'),
  CONSTRAINT age_rating_system_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.age_rating (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'age_rating' CONSTRAINT age_rating_kind_ck CHECK (kind = 'age_rating'),
  CONSTRAINT age_rating_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- Where attachable systems may attach. Data, not DDL: one row per (system, kind).
-- ----------------------------------------------------------------------------

CREATE TABLE core.attach_kind (
  system text NOT NULL CONSTRAINT attach_kind_system_ck CHECK (system ~ '^[a-z][a-z0-9_]*$'),
  kind   text NOT NULL CONSTRAINT attach_kind_kind_fk REFERENCES core.entity_kind (name) ON UPDATE CASCADE,
  PRIMARY KEY (system, kind)
);

-- PLANNING.md: genres and tags belong to primary media.
INSERT INTO core.attach_kind (system, kind)
SELECT s, k FROM (VALUES ('genre'), ('tag')) AS systems (s)
CROSS JOIN (VALUES ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie')) AS kinds (k);

-- ----------------------------------------------------------------------------
-- Genre and tag trees: zero or more parents, no loops.
-- Deleting a genre removes its own parent links; a genre that is still a parent
-- (or still attached to a work) cannot be deleted.
-- ----------------------------------------------------------------------------

CREATE TABLE core.genre_parent (
  genre_id    bigint NOT NULL,
  genre_kind  text NOT NULL DEFAULT 'genre' CONSTRAINT genre_parent_genre_kind_ck  CHECK (genre_kind = 'genre'),
  parent_id   bigint NOT NULL,
  parent_kind text NOT NULL DEFAULT 'genre' CONSTRAINT genre_parent_parent_kind_ck CHECK (parent_kind = 'genre'),
  PRIMARY KEY (genre_id, parent_id),
  CONSTRAINT genre_parent_self_ck CHECK (genre_id <> parent_id),
  CONSTRAINT genre_parent_genre_fk  FOREIGN KEY (genre_id, genre_kind)   REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT genre_parent_parent_fk FOREIGN KEY (parent_id, parent_kind) REFERENCES core.entity (id, kind) ON DELETE RESTRICT
);
CREATE INDEX genre_parent_parent_ix ON core.genre_parent (parent_id);

CREATE TABLE core.tag_parent (
  tag_id      bigint NOT NULL,
  tag_kind    text NOT NULL DEFAULT 'tag' CONSTRAINT tag_parent_tag_kind_ck    CHECK (tag_kind = 'tag'),
  parent_id   bigint NOT NULL,
  parent_kind text NOT NULL DEFAULT 'tag' CONSTRAINT tag_parent_parent_kind_ck CHECK (parent_kind = 'tag'),
  PRIMARY KEY (tag_id, parent_id),
  CONSTRAINT tag_parent_self_ck CHECK (tag_id <> parent_id),
  CONSTRAINT tag_parent_tag_fk    FOREIGN KEY (tag_id, tag_kind)       REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT tag_parent_parent_fk FOREIGN KEY (parent_id, parent_kind) REFERENCES core.entity (id, kind) ON DELETE RESTRICT
);
CREATE INDEX tag_parent_parent_ix ON core.tag_parent (parent_id);

-- Loop guard for any (child column, parent column) edge table.
-- TG_ARGV[0] = child column, TG_ARGV[1] = parent column.
-- Refuses an edge when the child is already an ancestor of the new parent.
CREATE FUNCTION core.trg_edge_no_loop() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  child_col  text := TG_ARGV[0];
  parent_col text := TG_ARGV[1];
  v_child    bigint := (to_jsonb(NEW) ->> child_col)::bigint;
  v_parent   bigint := (to_jsonb(NEW) ->> parent_col)::bigint;
  loops      boolean;
BEGIN
  EXECUTE format(
    'WITH RECURSIVE up (id) AS (
       SELECT %2$I FROM %3$I.%4$I WHERE %1$I = $1
       UNION
       SELECT e.%2$I FROM %3$I.%4$I e JOIN up ON e.%1$I = up.id
     )
     SELECT EXISTS (SELECT 1 FROM up WHERE id = $2)',
    child_col, parent_col, TG_TABLE_SCHEMA, TG_TABLE_NAME)
  INTO loops USING v_parent, v_child;
  IF loops THEN
    RAISE EXCEPTION 'tree: making % a parent of % would create a loop', v_parent, v_child
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER genre_parent_no_loop
  BEFORE INSERT OR UPDATE ON core.genre_parent
  FOR EACH ROW EXECUTE FUNCTION core.trg_edge_no_loop('genre_id', 'parent_id');

CREATE TRIGGER tag_parent_no_loop
  BEFORE INSERT OR UPDATE ON core.tag_parent
  FOR EACH ROW EXECUTE FUNCTION core.trg_edge_no_loop('tag_id', 'parent_id');

-- A genre or tag plus everything below it (for "filter by genre, include descendants").
CREATE FUNCTION core.genre_with_descendants(p_genre bigint) RETURNS SETOF bigint
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE down (id) AS (
    SELECT p_genre
    UNION
    SELECT gp.genre_id FROM core.genre_parent gp JOIN down ON gp.parent_id = down.id
  )
  SELECT id FROM down
$$;

CREATE FUNCTION core.tag_with_descendants(p_tag bigint) RETURNS SETOF bigint
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE down (id) AS (
    SELECT p_tag
    UNION
    SELECT tp.tag_id FROM core.tag_parent tp JOIN down ON tp.parent_id = down.id
  )
  SELECT id FROM down
$$;

-- ----------------------------------------------------------------------------
-- Attaching genres and tags to entities (kinds allowed by core.attach_kind).
-- ----------------------------------------------------------------------------

CREATE TABLE core.entity_genre (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  genre_id    bigint NOT NULL,
  genre_kind  text NOT NULL DEFAULT 'genre' CONSTRAINT entity_genre_genre_kind_ck CHECK (genre_kind = 'genre'),
  system      text NOT NULL DEFAULT 'genre' CONSTRAINT entity_genre_system_ck     CHECK (system = 'genre'),
  PRIMARY KEY (entity_id, genre_id),
  CONSTRAINT entity_genre_entity_fk  FOREIGN KEY (entity_id, entity_kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_genre_genre_fk   FOREIGN KEY (genre_id, genre_kind)   REFERENCES core.entity (id, kind) ON DELETE RESTRICT,
  CONSTRAINT entity_genre_allowed_fk FOREIGN KEY (system, entity_kind)    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX entity_genre_genre_ix ON core.entity_genre (genre_id);

CREATE TABLE core.entity_tag (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  tag_id      bigint NOT NULL,
  tag_kind    text NOT NULL DEFAULT 'tag' CONSTRAINT entity_tag_tag_kind_ck CHECK (tag_kind = 'tag'),
  system      text NOT NULL DEFAULT 'tag' CONSTRAINT entity_tag_system_ck   CHECK (system = 'tag'),
  PRIMARY KEY (entity_id, tag_id),
  CONSTRAINT entity_tag_entity_fk  FOREIGN KEY (entity_id, entity_kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_tag_tag_fk     FOREIGN KEY (tag_id, tag_kind)       REFERENCES core.entity (id, kind) ON DELETE RESTRICT,
  CONSTRAINT entity_tag_allowed_fk FOREIGN KEY (system, entity_kind)    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX entity_tag_tag_ix ON core.entity_tag (tag_id);

-- ----------------------------------------------------------------------------
-- Age ratings
-- A system (PEGI, ESRB, CERO) lists the regions it covers; each rating under it
-- may have a minimum age. Name, description, logo and icon come from titles,
-- texts and images. An entity carries at most one rating per system.
-- ----------------------------------------------------------------------------

-- ISO 3166-1 alpha-2 (JP, TR, US; EU is reserved in ISO for the European Union).
CREATE DOMAIN core.country_code AS text
  CONSTRAINT country_code_ck CHECK (VALUE ~ '^[A-Z]{2}$');

ALTER TABLE world.age_rating_system
  ADD COLUMN regions core.country_code[] NOT NULL DEFAULT '{}';

ALTER TABLE child.age_rating
  ADD COLUMN min_age smallint CONSTRAINT age_rating_min_age_ck CHECK (min_age BETWEEN 0 AND 99);

-- Lets a table require "this rating belongs to that system".
ALTER TABLE core.entity ADD CONSTRAINT entity_id_kind_parent_uq UNIQUE (id, kind, parent_id);

-- PLANNING.md: primary media, and releases or other child entities when needed.
INSERT INTO core.attach_kind (system, kind)
SELECT 'age_rating', k FROM (VALUES
  ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie'),
  ('season'), ('episode'), ('volume'), ('dlc'), ('release'), ('cut'), ('soundtrack')
) AS kinds (k);

CREATE TABLE core.entity_age_rating (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  rating_id   bigint NOT NULL,
  rating_kind text NOT NULL DEFAULT 'age_rating' CONSTRAINT entity_age_rating_rating_kind_ck CHECK (rating_kind = 'age_rating'),
  system_id   bigint NOT NULL,   -- filled from the rating when omitted
  system      text NOT NULL DEFAULT 'age_rating' CONSTRAINT entity_age_rating_system_ck CHECK (system = 'age_rating'),
  PRIMARY KEY (entity_id, system_id),   -- one rating per system per entity
  CONSTRAINT entity_age_rating_entity_fk  FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_age_rating_rating_fk  FOREIGN KEY (rating_id, rating_kind, system_id)
    REFERENCES core.entity (id, kind, parent_id) ON DELETE RESTRICT,
  CONSTRAINT entity_age_rating_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX entity_age_rating_rating_ix ON core.entity_age_rating (rating_id);

CREATE FUNCTION core.trg_entity_age_rating_fill_system() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.system_id IS NULL THEN
    SELECT e.parent_id INTO NEW.system_id FROM core.entity e WHERE e.id = NEW.rating_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER entity_age_rating_fill_system
  BEFORE INSERT OR UPDATE OF rating_id ON core.entity_age_rating
  FOR EACH ROW EXECUTE FUNCTION core.trg_entity_age_rating_fill_system();

-- ----------------------------------------------------------------------------
-- Images — for every entity
-- A file is identified by the SHA-256 of its bytes plus its format; the file on
-- disk is <sha256>.<format>. The same file may be used by several entities.
-- ----------------------------------------------------------------------------

CREATE TABLE core.image_format (
  code      text PRIMARY KEY CONSTRAINT image_format_code_ck CHECK (code ~ '^[a-z0-9]{2,5}$'),
  mime_type text NOT NULL CONSTRAINT image_format_mime_uq UNIQUE
                          CONSTRAINT image_format_mime_ck CHECK (mime_type ~ '^image/[a-z0-9.+-]+$')
);

INSERT INTO core.image_format (code, mime_type) VALUES
  ('jpg',  'image/jpeg'),
  ('png',  'image/png'),
  ('webp', 'image/webp'),
  ('avif', 'image/avif'),
  ('gif',  'image/gif'),
  ('svg',  'image/svg+xml');

CREATE TABLE core.image (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id  bigint NOT NULL CONSTRAINT image_entity_fk REFERENCES core.entity (id) ON DELETE CASCADE,
  image_type text NOT NULL CONSTRAINT image_type_fk REFERENCES core.image_type (code) ON UPDATE CASCADE,
  sha256     text NOT NULL CONSTRAINT image_sha256_ck CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  format     text NOT NULL CONSTRAINT image_format_fk REFERENCES core.image_format (code) ON UPDATE CASCADE,
  width      integer CONSTRAINT image_width_ck  CHECK (width > 0),    -- NULL for vector images
  height     integer CONSTRAINT image_height_ck CHECK (height > 0),
  byte_size  integer CONSTRAINT image_byte_size_ck CHECK (byte_size > 0),
  lang       core.lang_tag,       -- language of text shown in the image, if any
  region     core.country_code,   -- region-specific artwork, if any
  caption    core.labels,
  sort_order smallint NOT NULL DEFAULT 0,
  is_primary boolean NOT NULL DEFAULT false,   -- the one shown by default for this type
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT image_size_pair_ck CHECK ((width IS NULL) = (height IS NULL)),
  CONSTRAINT image_file_once_uq UNIQUE (entity_id, image_type, sha256, format)
);
CREATE UNIQUE INDEX image_primary_uq ON core.image (entity_id, image_type) WHERE is_primary;
CREATE INDEX image_entity_ix ON core.image (entity_id, image_type, sort_order);
CREATE INDEX image_file_ix   ON core.image (sha256, format);

-- ----------------------------------------------------------------------------
-- Original languages and countries of origin — primary media (PLANNING.md)
-- ----------------------------------------------------------------------------

INSERT INTO core.attach_kind (system, kind)
SELECT 'origin', k FROM (VALUES ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie')) AS kinds (k);

CREATE TABLE core.entity_original_language (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  lang        core.lang_tag NOT NULL,
  system      text NOT NULL DEFAULT 'origin' CONSTRAINT entity_original_language_system_ck CHECK (system = 'origin'),
  sort_order  smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (entity_id, lang),
  CONSTRAINT entity_original_language_entity_fk  FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_original_language_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);

CREATE TABLE core.entity_origin_country (
  entity_id   bigint NOT NULL,
  entity_kind text NOT NULL,
  country     core.country_code NOT NULL,
  system      text NOT NULL DEFAULT 'origin' CONSTRAINT entity_origin_country_system_ck CHECK (system = 'origin'),
  sort_order  smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (entity_id, country),
  CONSTRAINT entity_origin_country_entity_fk  FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_origin_country_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);

COMMIT;
