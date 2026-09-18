-- ============================================================================
-- Toradora!: the 25 TV episodes and the OVA (content). Needs 0001_toradora_works.sql.
--
-- Titles and air dates: en.wikipedia.org/wiki/List_of_Toradora!_episodes.
-- Dates are the calendar date in Japan (SCHEMA.md, Data conventions).
-- Aey: the OVA "The True Meaning of Bento" is an extra episode of the TV series,
-- not a work of its own, so it has no number.
-- Each episode runs about 24 minutes, the series' typical runtime.
-- ============================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

DO $$
DECLARE
  v_anime bigint; e record; v_episode bigint; ja bigint;
BEGIN
  SELECT e2.id INTO v_anime FROM core.entity e2
   WHERE e2.kind = 'anime'
     AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e2.id AND t.lang = 'en' AND t.text = 'Toradora!');
  IF v_anime IS NULL THEN
    RAISE EXCEPTION 'content: needs 0001_toradora_works.sql first';
  END IF;
  IF EXISTS (SELECT 1 FROM core.entity c WHERE c.parent_id = v_anime AND c.kind = 'episode') THEN
    RAISE EXCEPTION 'content: the Toradora! episodes are already loaded';
  END IF;

  FOR e IN
    SELECT * FROM (VALUES
      (1,  'Tiger and Dragon',                                '虎と竜',                 'Tora to Ryū',                       '2008-10-02'),
      (2,  'Ryūji and Taiga',                                 '竜児と大河',             'Ryūji to Taiga',                    '2008-10-09'),
      (3,  'Your Song',                                       '君の歌',                 'Kimi no Uta',                       '2008-10-16'),
      (4,  'That Moment''s Expression',                       'あのときの顔',           'Ano Toki no Kao',                   '2008-10-23'),
      (5,  'Ami Kawashima',                                   'かわしまあみ',           'Kawashima Ami',                     '2008-10-30'),
      (6,  'True Self',                                       'ほんとの自分',           'Honto no Jibun',                    '2008-11-06'),
      (7,  'Pool Opening',                                    'プールびらき',           'Pūru Biraki',                       '2008-11-13'),
      (8,  'For Whose Sake?',                                 'だれのため',             'Dare no Tame',                      '2008-11-20'),
      (9,  'Let''s Go to the Ocean, You Say.',                '海にいこうと君は',       'Umi ni Ikō to Kimi wa',             '2008-11-27'),
      (10, 'Fireworks',                                       '花火',                   'Hanabi',                            '2008-12-04'),
      (11, 'Ōhashi High School Cultural Festival (Part One)', '大橋高校文化祭（前編）', 'Ōhashi Kōkō Bunkasai (Zenpen)',     '2008-12-11'),
      (12, 'Ōhashi High School Cultural Festival (Part Two)', '大橋高校文化祭（中編）', 'Ōhashi Kōkō Bunkasai (Chūhen)',     '2008-12-18'),
      (13, 'Ōhashi High School Cultural Festival (Finale)',   '大橋高校文化祭（後篇）', 'Ōhashi Kōkō Bunkasai (Kōhen)',      '2008-12-25'),
      (14, 'The Palmtop Tiger of Happiness',                  'しあわせの手乗りタイガー', 'Shiawase no Tenori Taigā',        '2009-01-08'),
      (15, 'The Stars Are Far',                               '星は、遠く',             'Hoshi wa, Tōku',                    '2009-01-15'),
      (16, 'One Step Forward',                                '踏み出す一歩',           'Fumidasu Ippo',                     '2009-01-22'),
      (17, 'Mercury Retrogrades at Christmas',                'クリスマスに水星は逆行する', 'Kurisumasu ni Suisei wa Gyakkōsuru', '2009-01-29'),
      (18, 'Under the Fir Tree',                              'もみの木の下で',         'Momi no Ki no Shita de',            '2009-02-05'),
      (19, 'Christmas Eve Festival',                          '聖夜祭',                 'Seiyasai',                          '2009-02-12'),
      (20, 'Forever Like This',                               'ずっと、このまま',       'Zutto, Kono Mama',                  '2009-02-19'),
      (21, 'No Matter What',                                  'どうしたって',           'Dōshitatte',                        '2009-02-26'),
      (22, 'The Scene With You',                              '君のいる景色',           'Kimi no Iru Keshiki',               '2009-03-05'),
      (23, 'The Road That We Must Advance On',                '進むべき道',             'Susumu Beki Michi',                 '2009-03-12'),
      (24, 'Confession',                                      '告白',                   'Kokuhaku',                          '2009-03-19'),
      (25, 'Toradora!',                                       'とらドラ！',             'Toradora!',                         '2009-03-26'),
      -- the OVA, an extra episode with no number
      (NULL, 'The True Meaning of Bento',                     '弁当の極意',             'Bentō no Gokui',                    '2011-12-21')
    ) AS v (number, en_title, ja_title, ja_latn, aired_on)
  LOOP
    v_episode := core.create_entity('episode', NULL, v_anime);
    INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (v_episode, 'en', 'full', e.en_title, true);
    INSERT INTO core.title (entity_id, lang, title_type, text, native) VALUES (v_episode, 'ja', 'full', e.ja_title, true) RETURNING id INTO ja;
    INSERT INTO core.title (entity_id, lang, title_type, text, latinizes_id) VALUES (v_episode, 'ja-Latn', 'full', e.ja_latn, ja);
    UPDATE child.episode
       SET number_in_season = e.number, number_overall = e.number, aired_on = e.aired_on::core.partial_date, runtime_s = 24 * 60
     WHERE entity_id = v_episode;
  END LOOP;

  UPDATE core.entity e2 SET published_at = now()
   WHERE e2.published_at IS NULL AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e2.id);
END $$;

COMMIT;
