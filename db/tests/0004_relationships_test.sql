-- ============================================================================
-- Tests for migration 0004 — relationships, membership, appearances, credits.
-- Run with db/test.sh (applies migrations 0001..0004 to a fresh database).
--
-- Every expected refusal must be refused by the NAMED constraint or message.
-- Each section creates its own fixtures.
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

CREATE FUNCTION pg_temp.lbl(code text, col text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SELECT %I -> ''en'' ->> ''text'' FROM core.relation_type WHERE code = $1', col) INTO r USING code;
  RETURN r;
END $$;

-- relationship between two media works, by fixture name
CREATE FUNCTION pg_temp.rel(src text, rtype text, tgt text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
                   SELECT s.id, s.kind, %L, t.id, t.kind FROM core.entity s, core.entity t WHERE s.id = %s AND t.id = %s$f$,
                rtype, pg_temp.id(src), pg_temp.id(tgt)) $$;

-- what a work's page shows: the other work and what it is called from here
CREATE FUNCTION pg_temp.page(viewer text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT string_agg(line, '; ' ORDER BY line) FROM (
    SELECT i.name || ' - ' || (rt.target_labels -> 'en' ->> 'text') AS line
      FROM core.media_relation r JOIN core.relation_type rt ON rt.code = r.relation_type JOIN ids i ON i.id = r.target_id
     WHERE r.source_id = pg_temp.id(viewer)
    UNION ALL
    SELECT i.name || ' - ' || (rt.source_labels -> 'en' ->> 'text')
      FROM core.media_relation r JOIN core.relation_type rt ON rt.code = r.relation_type JOIN ids i ON i.id = r.source_id
     WHERE r.target_id = pg_temp.id(viewer)
  ) x $$;

CREATE FUNCTION pg_temp.frel(src text, rtype text, tgt text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (%s, %L, %s)$f$,
                pg_temp.id(src), rtype, pg_temp.id(tgt)) $$;

CREATE FUNCTION pg_temp.fpage(viewer text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT string_agg(line, '; ' ORDER BY line) FROM (
    SELECT i.name || ' - ' || (rt.target_labels -> 'en' ->> 'text') AS line
      FROM core.franchise_relation r JOIN core.relation_type rt ON rt.code = r.relation_type JOIN ids i ON i.id = r.target_id
     WHERE r.source_id = pg_temp.id(viewer)
    UNION ALL
    SELECT i.name || ' - ' || (rt.source_labels -> 'en' ->> 'text')
      FROM core.franchise_relation r JOIN core.relation_type rt ON rt.code = r.relation_type JOIN ids i ON i.id = r.source_id
     WHERE r.target_id = pg_temp.id(viewer)
  ) x $$;

CREATE FUNCTION pg_temp.app(ch text, tgt text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.appearance (character_id, target_id, target_kind)
                   SELECT %s, e.id, e.kind FROM core.entity e WHERE e.id = %s$f$, pg_temp.id(ch), pg_temp.id(tgt)) $$;

CREATE FUNCTION pg_temp.perf(p text, ch text, tgt text, ptype text, l text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang)
                   SELECT %s, %s, e.id, e.kind, %L, %s FROM core.entity e WHERE e.id = %s$f$,
                pg_temp.id(p), pg_temp.id(ch), ptype, coalesce(quote_literal(l), 'NULL'), pg_temp.id(tgt)) $$;

CREATE FUNCTION pg_temp.sc(p text, role text, tgt text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.staff_credit (person_id, role, target_id, target_kind)
                   SELECT %s, %L, e.id, e.kind FROM core.entity e WHERE e.id = %s$f$, pg_temp.id(p), role, pg_temp.id(tgt)) $$;

CREATE FUNCTION pg_temp.cc(c text, role text, tgt text) RETURNS text LANGUAGE sql AS $$
  SELECT format($f$INSERT INTO core.company_credit (company_id, role, target_id, target_kind)
                   SELECT %s, %L, e.id, e.kind FROM core.entity e WHERE e.id = %s$f$, pg_temp.id(c), role, pg_temp.id(tgt)) $$;

\echo '--- relationship types'
SELECT pg_temp.eq('16 relationship types', (SELECT count(*) FROM core.relation_type)::text, '16');
SELECT pg_temp.eq('types in order', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM core.relation_type),
  'sequel_of,side_story_of,spin_off_of,adaptation_of,retelling_of,recap_of,remake_of,reboot_of,remaster_of,port_of,enhanced_version_of,alternative_version_of,version_of,re_edit_of,alternative_universe,crossover');
SELECT pg_temp.eq('B sequel_of A: B''s page calls A', pg_temp.lbl('sequel_of', 'target_labels'), 'Prequel');
SELECT pg_temp.eq('B sequel_of A: A''s page calls B', pg_temp.lbl('sequel_of', 'source_labels'), 'Sequel');
SELECT pg_temp.eq('adaptation labels', pg_temp.lbl('adaptation_of', 'target_labels') || ' / ' || pg_temp.lbl('adaptation_of', 'source_labels'), 'Original work / Adaptation');
SELECT pg_temp.eq('side story labels', pg_temp.lbl('side_story_of', 'target_labels') || ' / ' || pg_temp.lbl('side_story_of', 'source_labels'), 'Main story / Side story');
SELECT pg_temp.eq('two-sided types', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM core.relation_type WHERE two_sided), 'alternative_universe,crossover');
SELECT pg_temp.t('custom type is a row', $$INSERT INTO core.relation_type (code, target_labels, source_labels, sort_order) VALUES ('compilation_of', core.label_en('Original work'), core.label_en('Compilation'), 170)$$, NULL);
SELECT pg_temp.t('two-sided type with different labels', $$INSERT INTO core.relation_type (code, target_labels, source_labels, two_sided) VALUES ('shares_setting', core.label_en('Shared setting'), core.label_en('Same setting'), true)$$, 'relation_type_two_sided_labels_ck');
SELECT pg_temp.t('type code must be lowercase', $$INSERT INTO core.relation_type (code, target_labels, source_labels) VALUES ('Sequel', core.label_en('a'), core.label_en('b'))$$, 'relation_type_code_ck');

\echo '--- relationships between works'
INSERT INTO ids VALUES ('p3', core.create_entity('game')), ('p3fes', core.create_entity('game')), ('p3p', core.create_entity('game')),
  ('p3r', core.create_entity('game')), ('smash', core.create_entity('game')),
  ('tora_ln', core.create_entity('light_novel')), ('tora_anime', core.create_entity('anime')), ('a_character', core.create_entity('character'));
INSERT INTO ids VALUES ('an_episode', core.create_entity('episode', NULL, pg_temp.id('tora_anime')));
SELECT pg_temp.t('P3 FES is an enhanced version of P3', pg_temp.rel('p3fes', 'enhanced_version_of', 'p3'), NULL);
SELECT pg_temp.t('P3P is a port of P3',                 pg_temp.rel('p3p', 'port_of', 'p3'), NULL);
SELECT pg_temp.t('P3R is a remake of P3',               pg_temp.rel('p3r', 'remake_of', 'p3'), NULL);
SELECT pg_temp.t('the anime adapts the light novel',    pg_temp.rel('tora_anime', 'adaptation_of', 'tora_ln'), NULL);
SELECT pg_temp.eq('P3''s page lists all three', pg_temp.page('p3'), 'p3fes - Enhanced version; p3p - Port; p3r - Remake');
SELECT pg_temp.eq('P3R''s page points back',    pg_temp.page('p3r'), 'p3 - Original work');
SELECT pg_temp.eq('the anime''s page',          pg_temp.page('tora_anime'), 'tora_ln - Original work');
SELECT pg_temp.eq('the light novel''s page',    pg_temp.page('tora_ln'), 'tora_anime - Adaptation');
SELECT pg_temp.t('a note on a link', format($$UPDATE core.media_relation SET note = 'adapts volumes 1-5' WHERE source_id = %s$$, pg_temp.id('tora_anime')), NULL);
SELECT pg_temp.t('crossover, lower id first', format($$INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  SELECT s.id, s.kind, 'crossover', t.id, t.kind FROM core.entity s, core.entity t WHERE s.id = least(%1$s, %2$s) AND t.id = greatest(%1$s, %2$s)$$, pg_temp.id('smash'), pg_temp.id('p3r')), NULL);
SELECT pg_temp.eq('crossover on Smash''s page', pg_temp.page('smash'), 'p3r - Crossover');
SELECT pg_temp.eq('crossover on P3R''s page',   pg_temp.page('p3r'), 'p3 - Original work; smash - Crossover');
SELECT pg_temp.t('crossover the wrong way round', format($$INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind)
  SELECT s.id, s.kind, 'crossover', t.id, t.kind FROM core.entity s, core.entity t WHERE s.id = greatest(%1$s, %2$s) AND t.id = least(%1$s, %2$s)$$, pg_temp.id('smash'), pg_temp.id('p3p')), 'media_relation_two_sided_order_ck');
SELECT pg_temp.t('a faked two-sided flag', format($$INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind, two_sided)
  SELECT s.id, s.kind, 'sequel_of', t.id, t.kind, true FROM core.entity s, core.entity t WHERE s.id = %s AND t.id = %s$$, pg_temp.id('p3fes'), pg_temp.id('p3p')), NULL);
SELECT pg_temp.eq('...stored as one-sided', (SELECT two_sided::text FROM core.media_relation WHERE relation_type = 'sequel_of'), 'false');
SELECT pg_temp.t('the same link twice',           pg_temp.rel('p3r', 'remake_of', 'p3'), 'media_relation_uq');
SELECT pg_temp.t('the same type back the other way', pg_temp.rel('p3', 'remake_of', 'p3r'), 'media_relation_pair_uq');
SELECT pg_temp.t('a work related to itself',      pg_temp.rel('p3', 'sequel_of', 'p3'), 'media_relation_self_ck');
SELECT pg_temp.t('an episode as target',          pg_temp.rel('p3', 'recap_of', 'an_episode'), 'media_relation_target_allowed_fk');
SELECT pg_temp.t('a character as source',         pg_temp.rel('a_character', 'spin_off_of', 'p3'), 'media_relation_source_allowed_fk');
SELECT pg_temp.t('unknown relationship type',     pg_temp.rel('p3r', 'inspired_by', 'p3'), 'media_relation_type_fk');
SELECT pg_temp.t('kind lies about the entity', format($$INSERT INTO core.media_relation (source_id, source_kind, relation_type, target_id, target_kind) VALUES (%s, 'anime', 'sequel_of', %s, 'game')$$, pg_temp.id('p3r'), pg_temp.id('p3')), 'media_relation_source_fk');
SELECT pg_temp.eq('links touching P3 before', (SELECT count(*) FROM core.media_relation WHERE source_id = pg_temp.id('p3') OR target_id = pg_temp.id('p3'))::text, '3');
SELECT pg_temp.t('delete P3',                 format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('p3')), NULL);
SELECT pg_temp.eq('its links went too',       (SELECT count(*) FROM core.media_relation WHERE source_id = pg_temp.id('p3') OR target_id = pg_temp.id('p3'))::text, '0');

\echo '--- relationships between franchises'
INSERT INTO ids VALUES ('smt', core.create_entity('franchise')), ('persona', core.create_entity('franchise')),
  ('etrian', core.create_entity('franchise')), ('lone', core.create_entity('franchise')), ('a_game', core.create_entity('game'));
SELECT pg_temp.t('Persona is a spin-off of SMT', pg_temp.frel('persona', 'spin_off_of', 'smt'), NULL);
SELECT pg_temp.t('Etrian is a spin-off of SMT',  pg_temp.frel('etrian', 'spin_off_of', 'smt'), NULL);
SELECT pg_temp.eq('SMT''s page',     pg_temp.fpage('smt'),     'etrian - Spin-off; persona - Spin-off');
SELECT pg_temp.eq('Persona''s page', pg_temp.fpage('persona'), 'smt - Main work');
SELECT pg_temp.t('franchise crossover, lower id first', format($$INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (least(%1$s, %2$s), 'crossover', greatest(%1$s, %2$s))$$, pg_temp.id('persona'), pg_temp.id('etrian')), NULL);
SELECT pg_temp.eq('crossover on Persona''s page', pg_temp.fpage('persona'), 'etrian - Crossover; smt - Main work');
SELECT pg_temp.eq('crossover on Etrian''s page',  pg_temp.fpage('etrian'),  'persona - Crossover; smt - Main work');
SELECT pg_temp.t('crossover the wrong way round', format($$INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (greatest(%1$s, %2$s), 'crossover', least(%1$s, %2$s))$$, pg_temp.id('smt'), pg_temp.id('lone')), 'franchise_relation_two_sided_order_ck');
SELECT pg_temp.t('the same link twice',            pg_temp.frel('persona', 'spin_off_of', 'smt'), 'franchise_relation_uq');
SELECT pg_temp.t('the same type back the other way', pg_temp.frel('smt', 'spin_off_of', 'persona'), 'franchise_relation_pair_uq');
SELECT pg_temp.t('a franchise related to itself',  pg_temp.frel('smt', 'sequel_of', 'smt'), 'franchise_relation_self_ck');
SELECT pg_temp.t('a game as a franchise',          pg_temp.frel('a_game', 'spin_off_of', 'smt'), 'franchise_relation_source_fk');
SELECT pg_temp.t('kind said to be game', format($$INSERT INTO core.franchise_relation (source_id, source_kind, relation_type, target_id) VALUES (%s, 'game', 'spin_off_of', %s)$$, pg_temp.id('a_game'), pg_temp.id('smt')), 'franchise_relation_source_kind_ck');
SELECT pg_temp.t('unknown type',                   pg_temp.frel('lone', 'inspired_by', 'smt'), 'franchise_relation_type_fk');
SELECT pg_temp.t('delete Etrian',       format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('etrian')), NULL);
SELECT pg_temp.eq('its links went too', (SELECT count(*) FROM core.franchise_relation WHERE source_id = pg_temp.id('etrian') OR target_id = pg_temp.id('etrian'))::text, '0');

\echo '--- franchise membership'
INSERT INTO ids VALUES ('member_game', core.create_entity('game')), ('member_anime', core.create_entity('anime'));
INSERT INTO ids VALUES ('member_ep', core.create_entity('episode', NULL, pg_temp.id('member_anime')));
INSERT INTO ids SELECT 'member_home', franchise_id FROM core.entity WHERE id = pg_temp.id('member_game');
SELECT pg_temp.eq('a new game has its home franchise',
  (SELECT string_agg(i.name || ':' || fa.is_home, ',') FROM core.entity_franchise_all fa JOIN ids i ON i.id = fa.franchise_id WHERE fa.entity_id = pg_temp.id('member_game')), 'member_home:true');
SELECT pg_temp.t('it also belongs to SMT', format($$INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'game', %s)$$, pg_temp.id('member_game'), pg_temp.id('smt')), NULL);
SELECT pg_temp.eq('now in two franchises',
  (SELECT string_agg(i.name || ':' || fa.is_home, ',' ORDER BY fa.is_home DESC) FROM core.entity_franchise_all fa JOIN ids i ON i.id = fa.franchise_id WHERE fa.entity_id = pg_temp.id('member_game')), 'member_home:true,smt:false');
SELECT pg_temp.t('adding the home franchise again', format($$INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'game', %s)$$, pg_temp.id('member_game'), pg_temp.id('member_home')), 'already the home franchise');
SELECT pg_temp.t('the same membership twice',      format($$INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'game', %s)$$, pg_temp.id('member_game'), pg_temp.id('smt')), 'entity_franchise_pkey');
SELECT pg_temp.t('membership for an episode',      format($$INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'episode', %s)$$, pg_temp.id('member_ep'), pg_temp.id('smt')), 'entity_franchise_allowed_fk');
SELECT pg_temp.t('a game used as the franchise',   format($$INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'anime', %s)$$, pg_temp.id('member_anime'), pg_temp.id('a_game')), 'entity_franchise_franchise_fk');
SELECT pg_temp.t('delete a franchise that has members', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('smt')), 'entity_franchise_franchise_fk');
SELECT pg_temp.t('delete the game',                format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('member_game')), NULL);
SELECT pg_temp.eq('its memberships went too',      (SELECT count(*) FROM core.entity_franchise_all WHERE entity_id = pg_temp.id('member_game'))::text, '0');

\echo '--- appearances'
INSERT INTO ids VALUES ('anime', core.create_entity('anime')), ('taiga', core.create_entity('character')), ('ryuji', core.create_entity('character')),
  ('kugimiya', core.create_entity('person')), ('cassidy', core.create_entity('person')), ('jcstaff', core.create_entity('company')),
  ('a_genre', core.create_entity('genre')), ('ln', core.create_entity('light_novel'));
INSERT INTO ids VALUES ('ep', core.create_entity('episode', NULL, pg_temp.id('anime'))), ('vol', core.create_entity('volume', NULL, pg_temp.id('ln')));
INSERT INTO ids SELECT 'anime_franchise', franchise_id FROM core.entity WHERE id = pg_temp.id('anime');
SELECT pg_temp.eq('appearance and credit attach kinds',
  (SELECT string_agg(system || ':' || cnt, ' ' ORDER BY system) FROM (SELECT system, count(*) cnt FROM core.attach_kind WHERE system IN ('appearance', 'credit') GROUP BY system) x), 'appearance:13 credit:13');
SELECT pg_temp.t('Taiga appears in the anime',     pg_temp.app('taiga', 'anime'), NULL);
SELECT pg_temp.t('Taiga also appears in episode 1', pg_temp.app('taiga', 'ep'), NULL);
SELECT pg_temp.t('roles: protagonist and main', format($$INSERT INTO core.appearance_role_link (appearance_id, role) SELECT a.id, r FROM core.appearance a, (VALUES ('protagonist'), ('main')) v(r) WHERE a.character_id = %s AND a.target_id = %s$$, pg_temp.id('taiga'), pg_temp.id('anime')), NULL);
SELECT pg_temp.eq('...both stored', (SELECT string_agg(l.role, ',' ORDER BY l.role) FROM core.appearance_role_link l JOIN core.appearance a ON a.id = l.appearance_id WHERE a.character_id = pg_temp.id('taiga') AND a.target_id = pg_temp.id('anime')), 'main,protagonist');
SELECT pg_temp.t('the same role twice', format($$INSERT INTO core.appearance_role_link (appearance_id, role) SELECT a.id, 'main' FROM core.appearance a WHERE a.character_id = %s AND a.target_id = %s$$, pg_temp.id('taiga'), pg_temp.id('anime')), 'appearance_role_link_pkey');
SELECT pg_temp.t('an unknown role', format($$INSERT INTO core.appearance_role_link (appearance_id, role) SELECT a.id, 'narrator' FROM core.appearance a WHERE a.character_id = %s AND a.target_id = %s$$, pg_temp.id('taiga'), pg_temp.id('anime')), 'appearance_role_link_role_fk');
SELECT pg_temp.t('the same character twice in one target', pg_temp.app('taiga', 'anime'), 'appearance_uq');
SELECT pg_temp.t('an appearance on a genre',    pg_temp.app('taiga', 'a_genre'), 'appearance_allowed_fk');
SELECT pg_temp.t('a person as the character',   pg_temp.app('kugimiya', 'anime'), 'appearance_character_fk');

\echo '--- performances'
SELECT pg_temp.t('Kugimiya voices Taiga in Japanese', pg_temp.perf('kugimiya', 'taiga', 'anime', 'voice', 'ja'), NULL);
SELECT pg_temp.t('an English dub voice',              pg_temp.perf('cassidy', 'taiga', 'anime', 'voice', 'en'), NULL);
SELECT pg_temp.t('the same person and language again', pg_temp.perf('kugimiya', 'taiga', 'anime', 'voice', 'ja'), 'performance_uq');
SELECT pg_temp.t('no language given',                 pg_temp.perf('kugimiya', 'ryuji', 'anime', 'voice', NULL), NULL);
SELECT pg_temp.t('no language given twice',           pg_temp.perf('kugimiya', 'ryuji', 'anime', 'voice', NULL), 'performance_uq');
SELECT pg_temp.t('a performance without an appearance row (PLANNING.md keeps these separate)', pg_temp.perf('cassidy', 'ryuji', 'ep', 'voice', 'en'), NULL);
SELECT pg_temp.t('a character used as the person',    pg_temp.perf('taiga', 'ryuji', 'anime', 'voice', 'ja'), 'performance_person_fk');
SELECT pg_temp.t('a performance on a franchise',      pg_temp.perf('kugimiya', 'taiga', 'anime_franchise', 'voice', 'ja'), 'performance_allowed_fk');
SELECT pg_temp.t('an unknown performance type',       pg_temp.perf('kugimiya', 'taiga', 'ep', 'narration', 'ja'), 'performance_type_fk');

\echo '--- staff and company credits'
SELECT pg_temp.t('director on the anime',          pg_temp.sc('kugimiya', 'director', 'anime'), NULL);
SELECT pg_temp.t('the same person also writer',    pg_temp.sc('kugimiya', 'writer', 'anime'), NULL);
SELECT pg_temp.t('the same person and role again', pg_temp.sc('kugimiya', 'director', 'anime'), 'staff_credit_uq');
SELECT pg_temp.t('director on an episode',         pg_temp.sc('cassidy', 'director', 'ep'), NULL);
SELECT pg_temp.t('a staff credit on a genre',      pg_temp.sc('cassidy', 'director', 'a_genre'), 'staff_credit_allowed_fk');
SELECT pg_temp.t('a company as the person',        pg_temp.sc('jcstaff', 'director', 'anime'), 'staff_credit_person_fk');
SELECT pg_temp.t('an unknown staff role',          pg_temp.sc('cassidy', 'gaffer', 'anime'), 'staff_credit_role_fk');
SELECT pg_temp.t('animation studio on the anime',  pg_temp.cc('jcstaff', 'animation_studio', 'anime'), NULL);
SELECT pg_temp.t('publisher on a volume',          pg_temp.cc('jcstaff', 'publisher', 'vol'), NULL);
SELECT pg_temp.t('the same company and role again', pg_temp.cc('jcstaff', 'animation_studio', 'anime'), 'company_credit_uq');
SELECT pg_temp.t('a person as the company',        pg_temp.cc('kugimiya', 'publisher', 'anime'), 'company_credit_company_fk');
SELECT pg_temp.eq('credits on the anime',
  (SELECT count(*) FROM core.staff_credit WHERE target_id = pg_temp.id('anime'))::text || '/' || (SELECT count(*) FROM core.company_credit WHERE target_id = pg_temp.id('anime'))::text, '2/1');

\echo '--- deletes'
SELECT pg_temp.t('delete the episode', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('ep')), NULL);
SELECT pg_temp.eq('its appearances, performances and credits went',
  ((SELECT count(*) FROM core.appearance WHERE target_id = pg_temp.id('ep'))
 + (SELECT count(*) FROM core.performance WHERE target_id = pg_temp.id('ep'))
 + (SELECT count(*) FROM core.staff_credit WHERE target_id = pg_temp.id('ep')))::text, '0');
SELECT pg_temp.t('delete Taiga', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('taiga')), NULL);
SELECT pg_temp.eq('her appearances, roles and performances went',
  ((SELECT count(*) FROM core.appearance WHERE character_id = pg_temp.id('taiga'))
 + (SELECT count(*) FROM core.performance WHERE character_id = pg_temp.id('taiga'))
 + (SELECT count(*) FROM core.appearance_role_link))::text, '0');

\echo '--- earlier layers still hold'
SELECT pg_temp.eq('every media entity has its work row',
  (SELECT count(*) FROM core.entity e JOIN media.work w ON w.entity_id = e.id WHERE e.family = 'media')::text,
  (SELECT count(*) FROM core.entity WHERE family = 'media')::text);
SELECT pg_temp.eq('addresses still resolve', (SELECT entity_id FROM core.resolve(core.address(pg_temp.id('p3r'))))::text, pg_temp.id('p3r')::text);
