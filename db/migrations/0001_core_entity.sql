-- ============================================================================
-- AML migration 0001 — core entity foundation
--
-- Every linkable/rateable thing is one row in core.entity plus one row in its
-- type table (media.anime, child.episode, world.person, ...). Every later layer
-- (titles, images, credits, relationships, Aey ratings, external data) points at
-- core.entity.id.
--
-- Public addresses are structured base32 paths, e.g. /01/0034/001:
--   media kinds    /{kind}/{home franchise}/{n}
--   world kinds    /{kind}/{n}
--   child kinds    {parent address}/{kind}/{n}
-- The address resolves to the internal id; joins never use the address.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

CREATE SCHEMA core;   -- entity foundation, addressing
CREATE SCHEMA media;  -- Anime, Manga, Light Novel, Game, Series, Movie
CREATE SCHEMA child;  -- Season, Episode, Volume, DLC, Release, Cut, Soundtrack
CREATE SCHEMA world;  -- Franchise, Character, Person, Company

-- ----------------------------------------------------------------------------
-- Kinds
-- ----------------------------------------------------------------------------

CREATE TABLE core.entity_kind (
  name      text PRIMARY KEY
            CONSTRAINT entity_kind_name_ck CHECK (name ~ '^[a-z][a-z_]*$'),
  code      text NOT NULL
            CONSTRAINT entity_kind_code_uq UNIQUE
            CONSTRAINT entity_kind_code_ck CHECK (code ~ '^[0-9A-HJKMNP-TV-Z]{2}$'),
  family    text NOT NULL
            CONSTRAINT entity_kind_family_ck CHECK (family IN ('media', 'child', 'world')),
  scope     text NOT NULL
            CONSTRAINT entity_kind_scope_ck CHECK (scope IN ('global', 'franchise', 'parent')),
  seq_width smallint NOT NULL
            CONSTRAINT entity_kind_width_ck CHECK (seq_width BETWEEN 2 AND 8),
  CONSTRAINT entity_kind_child_parent_ck    CHECK ((family = 'child') = (scope = 'parent')),
  CONSTRAINT entity_kind_media_franchise_ck CHECK ((family = 'media') = (scope = 'franchise')),
  CONSTRAINT entity_kind_name_family_uq UNIQUE (name, family),
  CONSTRAINT entity_kind_shape_uq       UNIQUE (name, family, scope)
);

COMMENT ON TABLE core.entity_kind IS
  'Entity kinds. code = 2-char base32 address segment. scope decides numbering: global, per home franchise (media), or per parent (child).';

-- Which child kinds may sit under which parents. Data, not DDL: add a row to allow a new placement.
CREATE TABLE core.entity_kind_parent (
  child_kind   text NOT NULL,
  child_family text NOT NULL DEFAULT 'child'
               CONSTRAINT entity_kind_parent_child_family_ck CHECK (child_family = 'child'),
  parent_kind  text NOT NULL REFERENCES core.entity_kind (name) ON UPDATE CASCADE,
  PRIMARY KEY (child_kind, parent_kind),
  CONSTRAINT entity_kind_parent_child_fk FOREIGN KEY (child_kind, child_family)
    REFERENCES core.entity_kind (name, family) ON UPDATE CASCADE
);

-- ----------------------------------------------------------------------------
-- Entity
-- ----------------------------------------------------------------------------

CREATE TABLE core.entity (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- internal join key, never public
  kind         text NOT NULL,
  family       text NOT NULL,
  scope        text NOT NULL,
  seq          integer NOT NULL
               CONSTRAINT entity_seq_ck CHECK (seq >= 0),
  franchise_id bigint,        -- home franchise; media kinds only
  parent_id    bigint,        -- parent entity; child kinds only
  parent_kind  text,
  published_at timestamptz,   -- NULL = draft
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT entity_id_kind_uq UNIQUE (id, kind),
  CONSTRAINT entity_shape_fk FOREIGN KEY (kind, family, scope)
    REFERENCES core.entity_kind (name, family, scope) ON UPDATE CASCADE,
  CONSTRAINT entity_franchise_scope_ck CHECK ((scope = 'franchise') = (franchise_id IS NOT NULL)),
  CONSTRAINT entity_parent_scope_ck    CHECK ((scope = 'parent') = (parent_id IS NOT NULL)),
  CONSTRAINT entity_parent_pair_ck     CHECK ((parent_id IS NULL) = (parent_kind IS NULL)),
  CONSTRAINT entity_parent_fk FOREIGN KEY (parent_id, parent_kind)
    REFERENCES core.entity (id, kind) ON DELETE RESTRICT,
  CONSTRAINT entity_parent_allowed_fk FOREIGN KEY (kind, parent_kind)
    REFERENCES core.entity_kind_parent (child_kind, parent_kind)
);

CREATE UNIQUE INDEX entity_seq_global_uq    ON core.entity (kind, seq)               WHERE scope = 'global';
CREATE UNIQUE INDEX entity_seq_franchise_uq ON core.entity (kind, franchise_id, seq) WHERE scope = 'franchise';
CREATE UNIQUE INDEX entity_seq_parent_uq    ON core.entity (parent_id, kind, seq)    WHERE scope = 'parent';
CREATE INDEX entity_franchise_ix ON core.entity (franchise_id) WHERE franchise_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Type tables — one per kind, in the schema named after its family.
-- Layer 2+ adds the type-specific columns.
-- The (entity_id, kind) foreign key guarantees the row matches its entity's kind.
-- ----------------------------------------------------------------------------

CREATE TABLE media.anime (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'anime' CONSTRAINT anime_kind_ck CHECK (kind = 'anime'),
  CONSTRAINT anime_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE media.manga (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'manga' CONSTRAINT manga_kind_ck CHECK (kind = 'manga'),
  CONSTRAINT manga_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE media.light_novel (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'light_novel' CONSTRAINT light_novel_kind_ck CHECK (kind = 'light_novel'),
  CONSTRAINT light_novel_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE media.game (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'game' CONSTRAINT game_kind_ck CHECK (kind = 'game'),
  CONSTRAINT game_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE media.series (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'series' CONSTRAINT series_kind_ck CHECK (kind = 'series'),
  CONSTRAINT series_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE media.movie (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'movie' CONSTRAINT movie_kind_ck CHECK (kind = 'movie'),
  CONSTRAINT movie_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

CREATE TABLE child.season (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'season' CONSTRAINT season_kind_ck CHECK (kind = 'season'),
  CONSTRAINT season_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.episode (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'episode' CONSTRAINT episode_kind_ck CHECK (kind = 'episode'),
  CONSTRAINT episode_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.volume (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'volume' CONSTRAINT volume_kind_ck CHECK (kind = 'volume'),
  CONSTRAINT volume_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.dlc (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'dlc' CONSTRAINT dlc_kind_ck CHECK (kind = 'dlc'),
  CONSTRAINT dlc_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.release (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'release' CONSTRAINT release_kind_ck CHECK (kind = 'release'),
  CONSTRAINT release_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.cut (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'cut' CONSTRAINT cut_kind_ck CHECK (kind = 'cut'),
  CONSTRAINT cut_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE child.soundtrack (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'soundtrack' CONSTRAINT soundtrack_kind_ck CHECK (kind = 'soundtrack'),
  CONSTRAINT soundtrack_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

CREATE TABLE world.franchise (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'franchise' CONSTRAINT franchise_kind_ck CHECK (kind = 'franchise'),
  CONSTRAINT franchise_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE world.character (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'character' CONSTRAINT character_kind_ck CHECK (kind = 'character'),
  CONSTRAINT character_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE world.person (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'person' CONSTRAINT person_kind_ck CHECK (kind = 'person'),
  CONSTRAINT person_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);
CREATE TABLE world.company (
  entity_id bigint PRIMARY KEY,
  kind      text NOT NULL DEFAULT 'company' CONSTRAINT company_kind_ck CHECK (kind = 'company'),
  CONSTRAINT company_entity_fk FOREIGN KEY (entity_id, kind) REFERENCES core.entity (id, kind) ON DELETE CASCADE
);

-- A media work's home franchise must be a real franchise.
ALTER TABLE core.entity ADD CONSTRAINT entity_home_franchise_fk
  FOREIGN KEY (franchise_id) REFERENCES world.franchise (entity_id) ON DELETE RESTRICT;

-- ----------------------------------------------------------------------------
-- Addressing
-- ----------------------------------------------------------------------------

-- Next number per (kind, owner). Numbers are never handed out twice, even after a move or delete.
CREATE TABLE core.address_counter (
  kind        text NOT NULL REFERENCES core.entity_kind (name) ON UPDATE CASCADE,
  scope_owner bigint NOT NULL DEFAULT 0,   -- 0 = global; else home franchise id or parent id
  next_seq    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (kind, scope_owner)
);

-- Retired addresses keep resolving to the entity that moved.
CREATE TABLE core.address_redirect (
  address    text PRIMARY KEY
             CONSTRAINT address_redirect_format_ck CHECK (address ~ '^(/[0-9A-HJKMNP-TV-Z]+)+$'),
  entity_id  bigint NOT NULL REFERENCES core.entity (id) ON DELETE CASCADE,
  retired_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX address_redirect_entity_ix ON core.address_redirect (entity_id);

-- ----------------------------------------------------------------------------
-- Seed: kinds
-- Code families by first character: 0x media, 1x child, 2x world.
-- seq_width = base32 characters for this kind's number (32^width values).
-- ----------------------------------------------------------------------------

INSERT INTO core.entity_kind (name, code, family, scope, seq_width) VALUES
  ('anime',       '01', 'media', 'franchise', 3),
  ('manga',       '02', 'media', 'franchise', 3),
  ('light_novel', '03', 'media', 'franchise', 3),
  ('game',        '04', 'media', 'franchise', 3),
  ('series',      '05', 'media', 'franchise', 3),
  ('movie',       '06', 'media', 'franchise', 3),
  ('season',      '11', 'child', 'parent',    2),
  ('episode',     '12', 'child', 'parent',    3),
  ('volume',      '13', 'child', 'parent',    3),
  ('dlc',         '14', 'child', 'parent',    3),
  ('release',     '15', 'child', 'parent',    3),
  ('cut',         '16', 'child', 'parent',    2),
  ('soundtrack',  '17', 'child', 'parent',    2),
  ('franchise',   '21', 'world', 'global',    4),
  ('character',   '22', 'world', 'global',    4),
  ('person',      '23', 'world', 'global',    5),
  ('company',     '24', 'world', 'global',    4);

-- ----------------------------------------------------------------------------
-- Seed: allowed placements (child kind -> parent kind)
-- A series episode must sit in a season; an anime episode may sit in the anime or a season.
-- A soundtrack sits directly under whatever it belongs to: any media, any other
-- child entity, or a franchise (franchise-wide compilations).
-- ----------------------------------------------------------------------------

INSERT INTO core.entity_kind_parent (child_kind, parent_kind) VALUES
  ('season',     'anime'),
  ('season',     'series'),
  ('episode',    'anime'),
  ('episode',    'season'),
  ('volume',     'manga'),
  ('volume',     'light_novel'),
  ('dlc',        'game'),
  ('release',    'game'),
  ('release',    'movie'),
  ('cut',        'movie'),
  ('soundtrack', 'anime'),
  ('soundtrack', 'manga'),
  ('soundtrack', 'light_novel'),
  ('soundtrack', 'game'),
  ('soundtrack', 'series'),
  ('soundtrack', 'movie'),
  ('soundtrack', 'season'),
  ('soundtrack', 'episode'),
  ('soundtrack', 'volume'),
  ('soundtrack', 'dlc'),
  ('soundtrack', 'release'),
  ('soundtrack', 'cut'),
  ('soundtrack', 'franchise');

-- ----------------------------------------------------------------------------
-- Functions
-- ----------------------------------------------------------------------------

-- Crockford base32: 0-9 A-Z without I L O U. Fixed width, zero-padded.
CREATE FUNCTION core.b32_encode(n bigint, width int) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  out text := '';
  v bigint := n;
BEGIN
  IF n < 0 THEN RAISE EXCEPTION 'b32_encode: negative number %', n; END IF;
  LOOP
    out := substr(alphabet, (v % 32)::int + 1, 1) || out;
    v := v / 32;
    EXIT WHEN v = 0;
  END LOOP;
  IF length(out) > width THEN RAISE EXCEPTION 'b32_encode: % does not fit in % characters', n, width; END IF;
  RETURN lpad(out, width, '0');
END $$;

-- Case-insensitive; I and L read as 1, O reads as 0. At most 12 characters (fits bigint).
CREATE FUNCTION core.b32_decode(s text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  t text := translate(upper(s), 'ILO', '110');
  v bigint := 0;
  c text;
BEGIN
  IF t !~ '^[0-9A-HJKMNP-TV-Z]{1,12}$' THEN RAISE EXCEPTION 'b32_decode: invalid segment "%"', s; END IF;
  FOREACH c IN ARRAY regexp_split_to_array(t, '') LOOP
    v := v * 32 + (strpos(alphabet, c) - 1);
  END LOOP;
  RETURN v;
END $$;

-- Hands out the next number for (kind, owner). Refuses when the kind's width is exhausted.
CREATE FUNCTION core.allocate_seq(p_kind text, p_owner bigint) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE s integer; w smallint;
BEGIN
  SELECT seq_width INTO w FROM core.entity_kind WHERE name = p_kind;
  IF w IS NULL THEN RAISE EXCEPTION 'allocate_seq: unknown kind %', p_kind; END IF;
  INSERT INTO core.address_counter AS c (kind, scope_owner, next_seq)
  VALUES (p_kind, coalesce(p_owner, 0), 2)
  ON CONFLICT (kind, scope_owner) DO UPDATE SET next_seq = c.next_seq + 1
  RETURNING c.next_seq - 1 INTO s;
  IF s >= power(32, w) THEN
    RAISE EXCEPTION 'allocate_seq: address space full for % under owner % (width %)', p_kind, p_owner, w;
  END IF;
  RETURN s;
END $$;

-- The creation path: entity row + type row together.
-- A media work created without a franchise gets its own new franchise.
CREATE FUNCTION core.create_entity(p_kind text, p_franchise_id bigint DEFAULT NULL, p_parent_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE k core.entity_kind; v_franchise bigint := p_franchise_id; v_parent_kind text; new_id bigint;
BEGIN
  SELECT * INTO k FROM core.entity_kind WHERE name = p_kind;
  IF NOT FOUND THEN RAISE EXCEPTION 'create_entity: unknown kind %', p_kind; END IF;
  IF k.scope = 'franchise' AND v_franchise IS NULL THEN
    v_franchise := core.create_entity('franchise');
  END IF;
  IF p_parent_id IS NOT NULL THEN
    SELECT e.kind INTO v_parent_kind FROM core.entity e WHERE e.id = p_parent_id;
  END IF;
  INSERT INTO core.entity (kind, family, scope, seq, franchise_id, parent_id, parent_kind)
  VALUES (k.name, k.family, k.scope,
          core.allocate_seq(k.name, CASE k.scope WHEN 'global' THEN 0
                                                 WHEN 'franchise' THEN v_franchise
                                                 ELSE p_parent_id END),
          v_franchise, p_parent_id, v_parent_kind)
  RETURNING id INTO new_id;
  EXECUTE format('INSERT INTO %I.%I (entity_id) VALUES ($1)', k.family, k.name) USING new_id;
  RETURN new_id;
END $$;

-- Canonical public address of an entity.
-- VOLATILE on purpose: a STABLE function reads the snapshot from the start of the calling
-- statement, so SELECT core.address(core.create_entity(...)) would not see the new row.
CREATE FUNCTION core.address(p_id bigint) RETURNS text
LANGUAGE plpgsql VOLATILE AS $$
DECLARE e core.entity; k core.entity_kind; f core.entity; fk core.entity_kind;
BEGIN
  SELECT * INTO e FROM core.entity WHERE id = p_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO k FROM core.entity_kind WHERE name = e.kind;
  IF e.scope = 'global' THEN
    RETURN '/' || k.code || '/' || core.b32_encode(e.seq, k.seq_width);
  ELSIF e.scope = 'franchise' THEN
    SELECT * INTO f FROM core.entity WHERE id = e.franchise_id;
    SELECT * INTO fk FROM core.entity_kind WHERE name = f.kind;
    RETURN '/' || k.code || '/' || core.b32_encode(f.seq, fk.seq_width) || '/' || core.b32_encode(e.seq, k.seq_width);
  ELSE
    RETURN core.address(e.parent_id) || '/' || k.code || '/' || core.b32_encode(e.seq, k.seq_width);
  END IF;
END $$;

-- Address -> entity. Live addresses first, then retired ones (redirected = true).
-- Unknown or malformed input returns no row; it never raises.
CREATE FUNCTION core.resolve(p_path text)
RETURNS TABLE (entity_id bigint, canonical text, redirected boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE segs text[]; n int; i int; k core.entity_kind; cur bigint; fid bigint; norm text;
BEGIN
  segs := array_remove(string_to_array(translate(upper(p_path), 'ILO', '110'), '/'), '');
  n := coalesce(array_length(segs, 1), 0);
  IF n = 0 THEN RETURN; END IF;
  norm := '/' || array_to_string(segs, '/');
  BEGIN
    SELECT * INTO k FROM core.entity_kind WHERE code = segs[1];
    IF FOUND AND k.scope = 'global' AND n >= 2 THEN
      SELECT e.id INTO cur FROM core.entity e
       WHERE e.kind = k.name AND e.scope = 'global' AND e.seq = core.b32_decode(segs[2]);
      i := 3;
    ELSIF FOUND AND k.scope = 'franchise' AND n >= 3 THEN
      SELECT e.id INTO fid FROM core.entity e
       WHERE e.kind = 'franchise' AND e.seq = core.b32_decode(segs[2]);
      SELECT e.id INTO cur FROM core.entity e
       WHERE e.kind = k.name AND e.franchise_id = fid AND e.seq = core.b32_decode(segs[3]);
      i := 4;
    END IF;
    WHILE cur IS NOT NULL AND i < n LOOP
      SELECT * INTO k FROM core.entity_kind WHERE code = segs[i];
      IF NOT FOUND THEN cur := NULL; EXIT; END IF;
      SELECT e.id INTO cur FROM core.entity e
       WHERE e.parent_id = cur AND e.kind = k.name AND e.seq = core.b32_decode(segs[i + 1]);
      i := i + 2;
    END LOOP;
  EXCEPTION WHEN raise_exception OR numeric_value_out_of_range THEN
    cur := NULL;
  END;
  IF cur IS NOT NULL AND i = n + 1 THEN
    RETURN QUERY SELECT cur, core.address(cur), false;
    RETURN;
  END IF;
  RETURN QUERY SELECT r.entity_id, core.address(r.entity_id), true
                 FROM core.address_redirect r WHERE r.address = norm;
END $$;

-- Move a media work to another home franchise. The old address of the work and of
-- every descendant is kept as a redirect; the work gets a fresh number in the new franchise.
CREATE FUNCTION core.move_to_franchise(p_id bigint, p_new_franchise bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE e core.entity;
BEGIN
  SELECT * INTO e FROM core.entity WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'move_to_franchise: entity % does not exist', p_id; END IF;
  IF e.scope <> 'franchise' THEN RAISE EXCEPTION 'move_to_franchise: % is not a media work', e.kind; END IF;
  IF e.franchise_id = p_new_franchise THEN RETURN; END IF;
  INSERT INTO core.address_redirect (address, entity_id)
  WITH RECURSIVE sub AS (
    SELECT id FROM core.entity WHERE id = p_id
    UNION ALL
    SELECT c.id FROM core.entity c JOIN sub ON c.parent_id = sub.id
  )
  SELECT core.address(sub.id), sub.id FROM sub;
  UPDATE core.entity
     SET franchise_id = p_new_franchise,
         seq          = core.allocate_seq(e.kind, p_new_franchise),
         updated_at   = now()
   WHERE id = p_id;
END $$;

COMMIT;
