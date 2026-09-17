-- ============================================================================
-- AML migration 0008 — display names for kinds
--
-- Every other option list keeps its labels in the database; kinds only had a
-- code. Pages need "Game", "Light Novel", "Cut / Edition". Setting the column
-- NOT NULL at the end makes this migration fail if any kind was left out.
-- See Documents/SCHEMA.md.
-- ============================================================================

BEGIN;

ALTER TABLE core.entity_kind ADD COLUMN labels core.labels;

UPDATE core.entity_kind k
   SET labels = core.label_en(v.label)
  FROM (VALUES
    ('anime',             'Anime'),
    ('manga',             'Manga'),
    ('light_novel',       'Light Novel'),
    ('game',              'Game'),
    ('series',            'Series'),
    ('movie',             'Movie'),
    ('season',            'Season'),
    ('episode',           'Episode'),
    ('volume',            'Volume'),
    ('dlc',               'DLC'),
    ('release',           'Release'),
    ('cut',               'Cut / Edition'),
    ('soundtrack',        'Soundtrack'),
    ('platform',          'Platform'),
    ('age_rating',        'Age Rating'),
    ('franchise',         'Franchise'),
    ('character',         'Character'),
    ('person',            'Person'),
    ('company',           'Company'),
    ('platform_family',   'Platform Family'),
    ('genre',             'Genre'),
    ('tag',               'Tag'),
    ('age_rating_system', 'Age Rating System')
  ) AS v (name, label)
 WHERE k.name = v.name;

ALTER TABLE core.entity_kind ALTER COLUMN labels SET NOT NULL;

COMMIT;
