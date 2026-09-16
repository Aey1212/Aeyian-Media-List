-- ============================================================================
-- AML migration 0004 — relationships, membership, appearances and credits
--
-- PLANNING.md: relationships are directional and stored once, and the display
-- derives each side's wording. Media works relate to media works; franchises
-- relate to franchises; media can belong to several franchises. Characters
-- appear in targets with roles; performances are contextual; staff and company
-- credits target media or child entities.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Relationship types
--
-- One row is stored: (source) is <type> (target).
-- Stored "B sequel_of A" reads on each page as:
--   B's page:  A — Prequel   (target_labels: what the target is)
--   A's page:  B — Sequel    (source_labels: what the source is)
-- Two-sided types (crossover, alternative universe) use the same label on both
-- sides and are stored once, in one direction only.
-- ----------------------------------------------------------------------------

-- ("symmetric" is a reserved word in SQL, hence two_sided.)
CREATE TABLE core.relation_type (
  code          text PRIMARY KEY CONSTRAINT relation_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  target_labels core.labels NOT NULL,   -- shown on the source's page, naming the target
  source_labels core.labels NOT NULL,   -- shown on the target's page, naming the source
  two_sided     boolean NOT NULL DEFAULT false,
  sort_order    smallint NOT NULL DEFAULT 0,
  CONSTRAINT relation_type_shape_uq UNIQUE (code, two_sided),
  CONSTRAINT relation_type_two_sided_labels_ck CHECK (NOT two_sided OR target_labels = source_labels)
);

INSERT INTO core.relation_type (code, target_labels, source_labels, two_sided, sort_order)
SELECT code, core.label_en(target_label), core.label_en(source_label), two_sided, sort
FROM (VALUES
  ('sequel_of',              'Prequel',             'Sequel',              false,  10),
  ('side_story_of',          'Main story',          'Side story',          false,  20),
  ('spin_off_of',            'Main work',           'Spin-off',            false,  30),
  ('adaptation_of',          'Original work',       'Adaptation',          false,  40),
  ('retelling_of',           'Original work',       'Retelling',           false,  50),
  ('recap_of',               'Original work',       'Recap',               false,  60),
  ('remake_of',              'Original work',       'Remake',              false,  70),
  ('reboot_of',              'Original work',       'Reboot',              false,  80),
  ('remaster_of',            'Original work',       'Remaster',            false,  90),
  ('port_of',                'Original work',       'Port',                false, 100),
  ('enhanced_version_of',    'Original work',       'Enhanced version',    false, 110),
  ('alternative_version_of', 'Original work',       'Alternative version', false, 120),
  ('version_of',             'Original work',       'Version',             false, 130),
  ('re_edit_of',             'Original work',       'Re-edit',             false, 140),
  ('alternative_universe',   'Alternative universe','Alternative universe', true, 150),
  ('crossover',              'Crossover',           'Crossover',            true, 160)
) AS v (code, target_label, source_label, two_sided, sort);

-- ----------------------------------------------------------------------------
-- Relationships between media works
--
-- PLANNING.md: directional, stored once, cross-media allowed.
-- A pair cannot hold the same type in both directions, and a two-sided type is
-- stored in one direction only (the lower id first).
-- ----------------------------------------------------------------------------

INSERT INTO core.attach_kind (system, kind)
SELECT 'relation', k FROM (VALUES ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie')) AS kinds (k);

CREATE TABLE core.media_relation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id     bigint NOT NULL,
  source_kind   text NOT NULL,
  relation_type text NOT NULL,
  target_id     bigint NOT NULL,
  target_kind   text NOT NULL,
  two_sided     boolean NOT NULL DEFAULT false,   -- filled from the type
  system        text NOT NULL DEFAULT 'relation' CONSTRAINT media_relation_system_ck CHECK (system = 'relation'),
  note          text,                              -- e.g. "adapts volumes 1-5"
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT media_relation_self_ck CHECK (source_id <> target_id),
  CONSTRAINT media_relation_two_sided_order_ck CHECK (NOT two_sided OR source_id < target_id),
  CONSTRAINT media_relation_uq UNIQUE (source_id, relation_type, target_id),
  CONSTRAINT media_relation_source_fk FOREIGN KEY (source_id, source_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT media_relation_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT media_relation_type_fk FOREIGN KEY (relation_type, two_sided)
    REFERENCES core.relation_type (code, two_sided),
  CONSTRAINT media_relation_source_allowed_fk FOREIGN KEY (system, source_kind)
    REFERENCES core.attach_kind (system, kind),
  CONSTRAINT media_relation_target_allowed_fk FOREIGN KEY (system, target_kind)
    REFERENCES core.attach_kind (system, kind)
);
-- one link per pair and type, whichever way round it was entered
CREATE UNIQUE INDEX media_relation_pair_uq ON core.media_relation
  (least(source_id, target_id), greatest(source_id, target_id), relation_type);
CREATE INDEX media_relation_target_ix ON core.media_relation (target_id);

-- two_sided always comes from the type, so it cannot disagree with it
CREATE FUNCTION core.trg_relation_fill_two_sided() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v boolean;
BEGIN
  SELECT rt.two_sided INTO v FROM core.relation_type rt WHERE rt.code = NEW.relation_type;
  IF FOUND THEN NEW.two_sided := v; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER media_relation_fill_two_sided
  BEFORE INSERT OR UPDATE OF relation_type ON core.media_relation
  FOR EACH ROW EXECUTE FUNCTION core.trg_relation_fill_two_sided();

-- ----------------------------------------------------------------------------
-- Relationships between franchises (PLANNING.md: "Persona can be a spin-off
-- franchise of Shin Megami Tensei"). Same type list and same rules.
-- ----------------------------------------------------------------------------

CREATE TABLE core.franchise_relation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id     bigint NOT NULL,
  source_kind   text NOT NULL DEFAULT 'franchise' CONSTRAINT franchise_relation_source_kind_ck CHECK (source_kind = 'franchise'),
  relation_type text NOT NULL,
  target_id     bigint NOT NULL,
  target_kind   text NOT NULL DEFAULT 'franchise' CONSTRAINT franchise_relation_target_kind_ck CHECK (target_kind = 'franchise'),
  two_sided     boolean NOT NULL DEFAULT false,
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT franchise_relation_self_ck CHECK (source_id <> target_id),
  CONSTRAINT franchise_relation_two_sided_order_ck CHECK (NOT two_sided OR source_id < target_id),
  CONSTRAINT franchise_relation_uq UNIQUE (source_id, relation_type, target_id),
  CONSTRAINT franchise_relation_source_fk FOREIGN KEY (source_id, source_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT franchise_relation_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT franchise_relation_type_fk FOREIGN KEY (relation_type, two_sided)
    REFERENCES core.relation_type (code, two_sided)
);
CREATE UNIQUE INDEX franchise_relation_pair_uq ON core.franchise_relation
  (least(source_id, target_id), greatest(source_id, target_id), relation_type);
CREATE INDEX franchise_relation_target_ix ON core.franchise_relation (target_id);

CREATE TRIGGER franchise_relation_fill_two_sided
  BEFORE INSERT OR UPDATE OF relation_type ON core.franchise_relation
  FOR EACH ROW EXECUTE FUNCTION core.trg_relation_fill_two_sided();

-- ----------------------------------------------------------------------------
-- Franchise membership
--
-- PLANNING.md: "Media can belong to franchises" (plural). Every work already has
-- one home franchise, which its address is built from (layer 1). This table adds
-- the further franchises a work belongs to; core.entity_franchise_all lists both.
-- ----------------------------------------------------------------------------

INSERT INTO core.attach_kind (system, kind)
SELECT 'franchise', k FROM (VALUES ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie')) AS kinds (k);

CREATE TABLE core.entity_franchise (
  entity_id      bigint NOT NULL,
  entity_kind    text NOT NULL,
  franchise_id   bigint NOT NULL,
  franchise_kind text NOT NULL DEFAULT 'franchise' CONSTRAINT entity_franchise_franchise_kind_ck CHECK (franchise_kind = 'franchise'),
  system         text NOT NULL DEFAULT 'franchise' CONSTRAINT entity_franchise_system_ck CHECK (system = 'franchise'),
  sort_order     smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (entity_id, franchise_id),
  CONSTRAINT entity_franchise_entity_fk FOREIGN KEY (entity_id, entity_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT entity_franchise_franchise_fk FOREIGN KEY (franchise_id, franchise_kind)
    REFERENCES core.entity (id, kind) ON DELETE RESTRICT,
  CONSTRAINT entity_franchise_allowed_fk FOREIGN KEY (system, entity_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX entity_franchise_franchise_ix ON core.entity_franchise (franchise_id);

-- The home franchise is not repeated here.
CREATE FUNCTION core.trg_entity_franchise_not_home() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.entity e WHERE e.id = NEW.entity_id AND e.franchise_id = NEW.franchise_id) THEN
    RAISE EXCEPTION 'franchise: % is already the home franchise of %', NEW.franchise_id, NEW.entity_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER entity_franchise_not_home
  BEFORE INSERT OR UPDATE ON core.entity_franchise
  FOR EACH ROW EXECUTE FUNCTION core.trg_entity_franchise_not_home();

-- Every franchise a work belongs to, home first.
CREATE VIEW core.entity_franchise_all AS
  SELECT e.id AS entity_id, e.kind AS entity_kind, e.franchise_id, true AS is_home, 0::smallint AS sort_order
    FROM core.entity e
   WHERE e.franchise_id IS NOT NULL
  UNION ALL
  SELECT ef.entity_id, ef.entity_kind, ef.franchise_id, false, ef.sort_order
    FROM core.entity_franchise ef;

-- ----------------------------------------------------------------------------
-- Appearances, performances and credits all target a media work or a child
-- entity (PLANNING.md: "Targets can be media or child entities").
-- ----------------------------------------------------------------------------

INSERT INTO core.attach_kind (system, kind)
SELECT s, k FROM (VALUES ('appearance'), ('credit')) AS systems (s)
CROSS JOIN (VALUES
  ('anime'), ('manga'), ('light_novel'), ('game'), ('series'), ('movie'),
  ('season'), ('episode'), ('volume'), ('dlc'), ('release'), ('cut'), ('soundtrack')
) AS kinds (k);

-- Character appearances: a character in a target, with one or more roles.
CREATE TABLE core.appearance (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  character_id   bigint NOT NULL,
  character_kind text NOT NULL DEFAULT 'character' CONSTRAINT appearance_character_kind_ck CHECK (character_kind = 'character'),
  target_id      bigint NOT NULL,
  target_kind    text NOT NULL,
  system         text NOT NULL DEFAULT 'appearance' CONSTRAINT appearance_system_ck CHECK (system = 'appearance'),
  note           text,
  sort_order     smallint NOT NULL DEFAULT 0,
  CONSTRAINT appearance_uq UNIQUE (character_id, target_id),
  CONSTRAINT appearance_character_fk FOREIGN KEY (character_id, character_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT appearance_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT appearance_allowed_fk FOREIGN KEY (system, target_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX appearance_target_ix ON core.appearance (target_id);

-- Roles of one appearance (Protagonist, Playable, Boss ...). The option list is
-- core.appearance_role from layer 3.
CREATE TABLE core.appearance_role_link (
  appearance_id bigint NOT NULL CONSTRAINT appearance_role_link_appearance_fk
                REFERENCES core.appearance (id) ON DELETE CASCADE,
  role          text NOT NULL CONSTRAINT appearance_role_link_role_fk
                REFERENCES core.appearance_role (code) ON UPDATE CASCADE,
  PRIMARY KEY (appearance_id, role)
);

-- Performances: Person + Character + Target + type + optional language and notes
-- (PLANNING.md). Alternate actors and dubs are separate rows.
CREATE TABLE core.performance (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id        bigint NOT NULL,
  person_kind      text NOT NULL DEFAULT 'person' CONSTRAINT performance_person_kind_ck CHECK (person_kind = 'person'),
  character_id     bigint NOT NULL,
  character_kind   text NOT NULL DEFAULT 'character' CONSTRAINT performance_character_kind_ck CHECK (character_kind = 'character'),
  target_id        bigint NOT NULL,
  target_kind      text NOT NULL,
  performance_type text NOT NULL CONSTRAINT performance_type_fk
                   REFERENCES core.performance_type (code) ON UPDATE CASCADE,
  lang             core.lang_tag,   -- dub language, when it matters
  system           text NOT NULL DEFAULT 'appearance' CONSTRAINT performance_system_ck CHECK (system = 'appearance'),
  note             text,
  sort_order       smallint NOT NULL DEFAULT 0,
  -- NULLS NOT DISTINCT so two rows without a language cannot repeat (PostgreSQL 15+)
  CONSTRAINT performance_uq UNIQUE NULLS NOT DISTINCT (person_id, character_id, target_id, performance_type, lang),
  CONSTRAINT performance_person_fk FOREIGN KEY (person_id, person_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT performance_character_fk FOREIGN KEY (character_id, character_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT performance_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT performance_allowed_fk FOREIGN KEY (system, target_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX performance_target_ix    ON core.performance (target_id);
CREATE INDEX performance_character_ix ON core.performance (character_id);

-- Staff credits: Person + Staff Role + Target + optional notes.
-- One person may hold several roles on one target (one row per role).
CREATE TABLE core.staff_credit (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  person_id   bigint NOT NULL,
  person_kind text NOT NULL DEFAULT 'person' CONSTRAINT staff_credit_person_kind_ck CHECK (person_kind = 'person'),
  role        text NOT NULL CONSTRAINT staff_credit_role_fk REFERENCES core.staff_role (code) ON UPDATE CASCADE,
  target_id   bigint NOT NULL,
  target_kind text NOT NULL,
  system      text NOT NULL DEFAULT 'credit' CONSTRAINT staff_credit_system_ck CHECK (system = 'credit'),
  note        text,
  sort_order  smallint NOT NULL DEFAULT 0,
  CONSTRAINT staff_credit_uq UNIQUE (person_id, role, target_id),
  CONSTRAINT staff_credit_person_fk FOREIGN KEY (person_id, person_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT staff_credit_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT staff_credit_allowed_fk FOREIGN KEY (system, target_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX staff_credit_target_ix ON core.staff_credit (target_id);

-- Company credits: Company + Company Role + Target + notes.
CREATE TABLE core.company_credit (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   bigint NOT NULL,
  company_kind text NOT NULL DEFAULT 'company' CONSTRAINT company_credit_company_kind_ck CHECK (company_kind = 'company'),
  role         text NOT NULL CONSTRAINT company_credit_role_fk REFERENCES core.company_role (code) ON UPDATE CASCADE,
  target_id    bigint NOT NULL,
  target_kind  text NOT NULL,
  system       text NOT NULL DEFAULT 'credit' CONSTRAINT company_credit_system_ck CHECK (system = 'credit'),
  note         text,
  sort_order   smallint NOT NULL DEFAULT 0,
  CONSTRAINT company_credit_uq UNIQUE (company_id, role, target_id),
  CONSTRAINT company_credit_company_fk FOREIGN KEY (company_id, company_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT company_credit_target_fk FOREIGN KEY (target_id, target_kind)
    REFERENCES core.entity (id, kind) ON DELETE CASCADE,
  CONSTRAINT company_credit_allowed_fk FOREIGN KEY (system, target_kind)
    REFERENCES core.attach_kind (system, kind)
);
CREATE INDEX company_credit_target_ix ON core.company_credit (target_id);

COMMIT;
