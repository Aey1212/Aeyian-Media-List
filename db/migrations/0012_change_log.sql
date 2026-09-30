-- ============================================================================
-- Migration 0012 — the change log.
--
-- Every edit made through the editor, the admin chat or the terminal is recorded:
-- what changed, from what to what, when, and through which door. The public site
-- only reads; this is the editor's history, and what an undo would use.
--
-- The entity is kept as a label too (its address and name at the time), so a row
-- stays readable after the entity itself is deleted.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

CREATE TABLE core.change_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  changed_at   timestamptz NOT NULL DEFAULT now(),
  via          text NOT NULL CONSTRAINT change_log_via_ck CHECK (via IN ('web', 'chat', 'terminal')),
  operation    text NOT NULL CONSTRAINT change_log_operation_ck CHECK (operation ~ '^[a-z][a-z0-9_]*$'),
  entity_id    bigint CONSTRAINT change_log_entity_fk REFERENCES core.entity (id) ON DELETE SET NULL,
  entity_label text NOT NULL,
  before       jsonb,
  after        jsonb,
  CONSTRAINT change_log_changed_ck CHECK (before IS DISTINCT FROM after)
);
CREATE INDEX change_log_entity_ix ON core.change_log (entity_id, changed_at DESC);
CREATE INDEX change_log_changed_ix ON core.change_log (changed_at DESC);

COMMIT;
