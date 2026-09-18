-- ============================================================================
-- Migration 0011 — the "Background" appearance role.
--
-- Aey, for Toradora!'s bit parts (a teacher with two lines): they belong on the
-- page, below the supporting cast. Roles are rows (PLANNING.md).
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

INSERT INTO core.appearance_role (code, labels, sort_order)
VALUES ('background', core.label_en('Background'), 80);

COMMIT;
