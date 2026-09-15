-- ============================================================================
-- Tests for migration 0001 — core entity foundation.
-- Run with db/test.sh (applies migrations to a fresh database first).
--
-- Every expected refusal must be refused by the NAMED constraint or message;
-- a refusal for any other reason is a FAIL.
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

-- ----------------------------------------------------------------------------
-- Fixtures (creation order fixes the numbers asserted below)
-- Franchise counter starts at 100 so Toradora is base32 "0034".
-- ----------------------------------------------------------------------------
INSERT INTO core.address_counter (kind, scope_owner, next_seq) VALUES ('franchise', 0, 100)
  ON CONFLICT (kind, scope_owner) DO UPDATE SET next_seq = 100;

INSERT INTO ids VALUES ('toradora',   core.create_entity('franchise'));                                  -- 100 = 0034
INSERT INTO ids VALUES ('tora_tv',    core.create_entity('anime',       pg_temp.id('toradora')));
INSERT INTO ids VALUES ('tora_ln',    core.create_entity('light_novel', pg_temp.id('toradora')));
INSERT INTO ids VALUES ('tora_manga', core.create_entity('manga',       pg_temp.id('toradora')));
INSERT INTO ids VALUES ('tora_ova',   core.create_entity('anime',       pg_temp.id('toradora')));
INSERT INTO ids VALUES ('tv_s1',      core.create_entity('season',  NULL, pg_temp.id('tora_tv')));
INSERT INTO ids VALUES ('tv_s1_e1',   core.create_entity('episode', NULL, pg_temp.id('tv_s1')));
INSERT INTO ids VALUES ('tv_e1',      core.create_entity('episode', NULL, pg_temp.id('tora_tv')));
INSERT INTO ids VALUES ('ova_e1',     core.create_entity('episode', NULL, pg_temp.id('tora_ova')));
INSERT INTO ids VALUES ('ln_v1',      core.create_entity('volume',  NULL, pg_temp.id('tora_ln')));
INSERT INTO ids VALUES ('tora_ost',   core.create_entity('soundtrack', NULL, pg_temp.id('toradora')));
INSERT INTO ids VALUES ('taiga',      core.create_entity('character'));
INSERT INTO ids VALUES ('person1',    core.create_entity('person'));
INSERT INTO ids VALUES ('atlus',      core.create_entity('company'));
INSERT INTO ids VALUES ('persona',    core.create_entity('franchise'));                                  -- 101 = 0035
INSERT INTO ids VALUES ('p3r',        core.create_entity('game', pg_temp.id('persona')));
INSERT INTO ids VALUES ('p3r_dlc',    core.create_entity('dlc',        NULL, pg_temp.id('p3r')));
INSERT INTO ids VALUES ('p3r_rel',    core.create_entity('release',    NULL, pg_temp.id('p3r')));
INSERT INTO ids VALUES ('p3r_rel_ost',core.create_entity('soundtrack', NULL, pg_temp.id('p3r_rel')));
INSERT INTO ids VALUES ('undertale',  core.create_entity('game'));                                       -- own franchise 102 = 0036
INSERT INTO ids VALUES ('a_series',   core.create_entity('series'));                                     -- own franchise 103 = 0037
INSERT INTO ids VALUES ('series_s1',  core.create_entity('season',  NULL, pg_temp.id('a_series')));
INSERT INTO ids VALUES ('series_e1',  core.create_entity('episode', NULL, pg_temp.id('series_s1')));
INSERT INTO ids VALUES ('series_ost', core.create_entity('soundtrack', NULL, pg_temp.id('a_series')));
INSERT INTO ids VALUES ('a_movie',    core.create_entity('movie'));                                      -- own franchise 104 = 0038
INSERT INTO ids VALUES ('movie_cut',  core.create_entity('cut',     NULL, pg_temp.id('a_movie')));
INSERT INTO ids VALUES ('movie_rel',  core.create_entity('release', NULL, pg_temp.id('a_movie')));

\echo '--- kinds'
SELECT pg_temp.t('media kind cannot be global',         $$INSERT INTO core.entity_kind VALUES ('webtoon','07','media','global',3)$$,   'entity_kind_media_franchise_ck');
SELECT pg_temp.t('world kind cannot be franchise-scoped',$$INSERT INTO core.entity_kind VALUES ('mascot','25','world','franchise',3)$$, 'entity_kind_media_franchise_ck');
SELECT pg_temp.t('child kind must be parent-scoped',    $$INSERT INTO core.entity_kind VALUES ('track','18','child','global',3)$$,     'entity_kind_child_parent_ck');
SELECT pg_temp.t('kind code rejects U',                 $$INSERT INTO core.entity_kind VALUES ('webtoon','0U','media','franchise',3)$$,'entity_kind_code_ck');
SELECT pg_temp.t('kind code must be unique',            $$INSERT INTO core.entity_kind VALUES ('serial','01','media','franchise',3)$$, 'entity_kind_code_uq');
SELECT pg_temp.t('only child kinds can have parents',   $$INSERT INTO core.entity_kind_parent (child_kind, parent_kind) VALUES ('anime','franchise')$$, 'entity_kind_parent_child_fk');

\echo '--- addresses'
SELECT pg_temp.eq('Toradora franchise',                core.address(pg_temp.id('toradora')),    '/21/0034');
SELECT pg_temp.eq('Toradora anime',                    core.address(pg_temp.id('tora_tv')),     '/01/0034/001');
SELECT pg_temp.eq('Toradora light novel',              core.address(pg_temp.id('tora_ln')),     '/03/0034/001');
SELECT pg_temp.eq('Toradora manga',                    core.address(pg_temp.id('tora_manga')),  '/02/0034/001');
SELECT pg_temp.eq('second Toradora anime',             core.address(pg_temp.id('tora_ova')),    '/01/0034/002');
SELECT pg_temp.eq('season under anime',                core.address(pg_temp.id('tv_s1')),       '/01/0034/001/11/01');
SELECT pg_temp.eq('episode under season',              core.address(pg_temp.id('tv_s1_e1')),    '/01/0034/001/11/01/12/001');
SELECT pg_temp.eq('episode directly under anime',      core.address(pg_temp.id('tv_e1')),       '/01/0034/001/12/001');
SELECT pg_temp.eq('volume under light novel',          core.address(pg_temp.id('ln_v1')),       '/03/0034/001/13/001');
SELECT pg_temp.eq('soundtrack under franchise',        core.address(pg_temp.id('tora_ost')),    '/21/0034/17/01');
SELECT pg_temp.eq('character is global',               core.address(pg_temp.id('taiga')),       '/22/0001');
SELECT pg_temp.eq('person is global',                  core.address(pg_temp.id('person1')),     '/23/00001');
SELECT pg_temp.eq('company is global',                 core.address(pg_temp.id('atlus')),       '/24/0001');
SELECT pg_temp.eq('game in Persona franchise',         core.address(pg_temp.id('p3r')),         '/04/0035/001');
SELECT pg_temp.eq('DLC under game',                    core.address(pg_temp.id('p3r_dlc')),     '/04/0035/001/14/001');
SELECT pg_temp.eq('release under game',                core.address(pg_temp.id('p3r_rel')),     '/04/0035/001/15/001');
SELECT pg_temp.eq('soundtrack under game release',     core.address(pg_temp.id('p3r_rel_ost')), '/04/0035/001/15/001/17/01');
SELECT pg_temp.eq('standalone game gets own franchise', core.address(pg_temp.id('undertale')),   '/04/0036/001');
SELECT pg_temp.eq('standalone series gets own franchise', core.address(pg_temp.id('a_series')), '/05/0037/001');
SELECT pg_temp.eq('series episode under season',       core.address(pg_temp.id('series_e1')),   '/05/0037/001/11/01/12/001');
SELECT pg_temp.eq('soundtrack directly under series',  core.address(pg_temp.id('series_ost')),  '/05/0037/001/17/01');
SELECT pg_temp.eq('standalone movie gets own franchise', core.address(pg_temp.id('a_movie')),   '/06/0038/001');
SELECT pg_temp.eq('cut under movie',                   core.address(pg_temp.id('movie_cut')),   '/06/0038/001/16/01');
SELECT pg_temp.eq('release under movie',               core.address(pg_temp.id('movie_rel')),   '/06/0038/001/15/001');
SELECT pg_temp.eq('own franchises are real franchises',(SELECT count(*) FROM world.franchise)::text, '5');
SELECT pg_temp.eq('address visible in the creating statement', core.address(core.create_entity('company')), '/24/0002');
SELECT pg_temp.eq('every kind has at least one entity',
  (SELECT string_agg(k.name, ',' ORDER BY k.name) FROM core.entity_kind k WHERE NOT EXISTS (SELECT 1 FROM core.entity e WHERE e.kind = k.name)), NULL);

\echo '--- integrity'
SELECT pg_temp.t('media work with no franchise (raw insert)', $$INSERT INTO core.entity (kind,family,scope,seq) VALUES ('anime','media','franchise',50)$$, 'entity_franchise_scope_ck');
SELECT pg_temp.t('character given a franchise',   format($$SELECT core.create_entity('character', %s)$$, pg_temp.id('toradora')), 'entity_franchise_scope_ck');
SELECT pg_temp.t('person given a parent',         format($$SELECT core.create_entity('person', NULL, %s)$$, pg_temp.id('tora_tv')), 'entity_parent_scope_ck');
SELECT pg_temp.t('child with no parent',          $$SELECT core.create_entity('episode')$$, 'entity_parent_scope_ck');
SELECT pg_temp.t('episode under a game',          format($$SELECT core.create_entity('episode', NULL, %s)$$, pg_temp.id('p3r')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('series episode outside a season', format($$SELECT core.create_entity('episode', NULL, %s)$$, pg_temp.id('a_series')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('soundtrack under a character',  format($$SELECT core.create_entity('soundtrack', NULL, %s)$$, pg_temp.id('taiga')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('soundtrack under a soundtrack', format($$SELECT core.create_entity('soundtrack', NULL, %s)$$, pg_temp.id('tora_ost')), 'entity_parent_allowed_fk');
SELECT pg_temp.t('duplicate number in scope',     format($$INSERT INTO core.entity (kind,family,scope,seq,franchise_id) VALUES ('anime','media','franchise',1,%s)$$, pg_temp.id('toradora')), 'entity_seq_franchise_uq');
SELECT pg_temp.t('home franchise is not a franchise', format($$INSERT INTO core.entity (kind,family,scope,seq,franchise_id) VALUES ('game','media','franchise',5,%s)$$, pg_temp.id('tora_tv')), 'entity_home_franchise_fk');
SELECT pg_temp.t('family lies about kind',        format($$INSERT INTO core.entity (kind,family,scope,seq,franchise_id) VALUES ('anime','world','franchise',7,%s)$$, pg_temp.id('toradora')), 'entity_shape_fk');
SELECT pg_temp.t('anime row on a light-novel entity', format($$INSERT INTO media.anime (entity_id) VALUES (%s)$$, pg_temp.id('tora_ln')), 'anime_entity_fk');
SELECT pg_temp.t('change kind while type row exists', format($$UPDATE core.entity SET kind = 'game' WHERE id = %s$$, pg_temp.id('tora_manga')), 'manga_entity_fk');
WITH x AS (INSERT INTO core.entity (kind,family,scope,seq,franchise_id) VALUES ('anime','media','franchise',900,pg_temp.id('toradora')) RETURNING id)
INSERT INTO ids SELECT 'bare', id FROM x;
SELECT pg_temp.t('control: kind change with no type row', format($$UPDATE core.entity SET kind = 'game' WHERE id = %s$$, pg_temp.id('bare')), NULL);
SELECT pg_temp.t('delete anime that has episodes',  format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('tora_tv')), 'entity_parent_fk');
SELECT pg_temp.t('delete franchise that has works', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('persona')), 'entity_home_franchise_fk');
SELECT pg_temp.eq('new entities start as drafts', (SELECT count(*) FILTER (WHERE published_at IS NOT NULL) FROM core.entity)::text, '0');

\echo '--- resolve'
SELECT pg_temp.eq('resolve /01/0034/001',            (SELECT entity_id FROM core.resolve('/01/0034/001'))::text, pg_temp.id('tora_tv')::text);
SELECT pg_temp.eq('resolve lowercase, O for 0',      (SELECT entity_id FROM core.resolve('/o1/oo34/oo1/'))::text, pg_temp.id('tora_tv')::text);
SELECT pg_temp.eq('resolve deep episode',            (SELECT entity_id FROM core.resolve('/01/0034/001/11/01/12/001'))::text, pg_temp.id('tv_s1_e1')::text);
SELECT pg_temp.eq('resolve soundtrack under release',(SELECT entity_id FROM core.resolve('/04/0035/001/15/001/17/01'))::text, pg_temp.id('p3r_rel_ost')::text);
SELECT pg_temp.eq('resolve soundtrack under franchise', (SELECT entity_id FROM core.resolve('/21/0034/17/01'))::text, pg_temp.id('tora_ost')::text);
SELECT pg_temp.eq('resolve global character',        (SELECT entity_id FROM core.resolve('/22/0001'))::text, pg_temp.id('taiga')::text);
SELECT pg_temp.eq('unknown number -> nothing',       (SELECT count(*) FROM core.resolve('/01/0034/0ZZ'))::text, '0');
SELECT pg_temp.eq('invalid character -> nothing',    (SELECT count(*) FROM core.resolve('/01/00U4/001'))::text, '0');
SELECT pg_temp.eq('overlong segment -> nothing',     (SELECT count(*) FROM core.resolve('/23/ZZZZZZZZZZZZZZZZZZZZ'))::text, '0');
SELECT pg_temp.eq('dangling kind code -> nothing',   (SELECT count(*) FROM core.resolve('/01/0034/001/12'))::text, '0');
SELECT pg_temp.eq('child kind cannot start an address', (SELECT count(*) FROM core.resolve('/12/001'))::text, '0');

\echo '--- move, redirects, no reuse'
INSERT INTO ids VALUES ('side', core.create_entity('franchise'));                                        -- 105 = 0039
SELECT pg_temp.t('move second anime to another franchise', format($$SELECT core.move_to_franchise(%s, %s)$$, pg_temp.id('tora_ova'), pg_temp.id('side')), NULL);
SELECT pg_temp.eq('moved anime has a new address',   core.address(pg_temp.id('tora_ova')), '/01/0039/001');
SELECT pg_temp.eq('old address redirects',           (SELECT entity_id || ' ' || canonical || ' ' || redirected FROM core.resolve('/01/0034/002')), pg_temp.id('tora_ova') || ' /01/0039/001 true');
SELECT pg_temp.eq('old child address redirects',     (SELECT entity_id || ' ' || redirected FROM core.resolve('/01/0034/002/12/001')), pg_temp.id('ova_e1') || ' true');
SELECT pg_temp.eq('new child address is live',       (SELECT entity_id || ' ' || redirected FROM core.resolve('/01/0039/001/12/001')), pg_temp.id('ova_e1') || ' false');
INSERT INTO ids VALUES ('tora_later', core.create_entity('anime', pg_temp.id('toradora')));
SELECT pg_temp.eq('freed number 002 is not reused',  core.address(pg_temp.id('tora_later')), '/01/0034/003');
SELECT pg_temp.t('move a non-media entity',          format($$SELECT core.move_to_franchise(%s, %s)$$, pg_temp.id('taiga'), pg_temp.id('side')), 'is not a media work');

\echo '--- deletes'
INSERT INTO ids VALUES ('lonely', core.create_entity('franchise'));
INSERT INTO ids VALUES ('lonely_ost', core.create_entity('soundtrack', NULL, pg_temp.id('lonely')));
SELECT pg_temp.t('delete franchise that has a soundtrack', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('lonely')), 'entity_parent_fk');
SELECT pg_temp.t('delete leaf removes its type row', format($$DELETE FROM core.entity WHERE id = %s$$, pg_temp.id('lonely_ost')), NULL);
SELECT pg_temp.eq('type row gone with its entity',   (SELECT count(*) FROM child.soundtrack WHERE entity_id = pg_temp.id('lonely_ost'))::text, '0');

\echo '--- capacity'
UPDATE core.address_counter SET next_seq = 1024 WHERE kind = 'season' AND scope_owner = pg_temp.id('tora_tv');
SELECT pg_temp.t('season 1025 exceeds 2-character width', format($$SELECT core.create_entity('season', NULL, %s)$$, pg_temp.id('tora_tv')), 'address space full');
SELECT pg_temp.eq('episode 1100 fits 3 characters',  core.b32_encode(1100, 3), '12C');
