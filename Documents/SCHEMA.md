# Aeyian Media List — Database Schema

Status (2026/09/16): **Layers 1–5 written and tested** (`db/migrations/0001_core_entity.sql`,
`0002_media_work.sql`, `0003_reusable_systems.sql`, `0004_relationships.sql`, `0005_child_entities.sql`;
`db/test.sh`: 73 + 94 + 149 + 98 + 104 = 518 passed, 0 failed). Layers 6–7 not started.

## Engine and modules

PostgreSQL 16 (15 or newer required: layer 4 uses `UNIQUE NULLS NOT DISTINCT`). Picked for
modularity: each layer lives in its own schema, reusable types are declared once as domains, and
`ALTER TABLE` can evolve existing tables without rebuilding them.

| Schema  | Holds |
|---------|-------|
| `core`  | Entity foundation, kinds, addressing, shared value types, titles, texts, images, genre/tag trees, age ratings, role lists, origins, relationships, franchise membership, appearances, performances, credits |
| `media` | Anime, Manga, Light Novel, Game, Series, Movie; `media.work`; media option lists; release schedules |
| `child` | Season, Episode, Volume, DLC, Release, Cut, Soundtrack, Age Rating, Platform; plus volume ISBNs, release languages, soundtrack tracks, episode themes |
| `world` | Franchise, Character, Person, Company, Genre, Tag, Age Rating System, Platform Family |

Extension: `pg_trgm` (title search).

---

## Layer 1 — Entity foundation

### Entity model

Everything linkable or rateable is **one row in `core.entity` plus one row in its type table**
(`media.anime`, `child.episode`, `world.person`, …). Every later system — titles, images, genres,
credits, relationships, Aey ratings, external data — points at `core.entity.id`.

`core.entity.id` is an internal join key. It is never shown publicly.

| Column | Meaning |
|---|---|
| `kind`, `family`, `scope` | What the entity is; must match a row in `core.entity_kind` |
| `seq` | Its number inside its scope (see Addresses) |
| `franchise_id` | Home franchise — media works only |
| `parent_id`, `parent_kind` | Parent entity — child kinds only |
| `published_at` | `NULL` = draft, hidden from the public site |
| `created_at`, `updated_at` | UTC. The backend sets `updated_at` in the same transaction as an edit |

### Addresses

Public URLs are structured IDs, not slugs.

```
media work   /{kind}/{home franchise}/{n}        /01/0034/001
world        /{kind}/{n}                         /22/0001
child        {parent address}/{kind}/{n}         /01/0034/001/12/001
```

| Example | Address |
|---|---|
| Toradora (franchise) | `/21/0034` |
| Toradora anime | `/01/0034/001` |
| Toradora light novel | `/03/0034/001` |
| Episode 1 in season 1 of that anime | `/01/0034/001/11/01/12/001` |
| Persona 3 Reload | `/04/0035/001` |
| Soundtrack of a P3R release | `/04/0035/001/15/001/17/01` |
| Franchise-wide soundtrack | `/21/0034/17/01` |
| Taiga (character) | `/22/0001` |
| PEGI 16 | `/29/01/19/01` |

Rules:

- **Encoding:** Crockford base32 (`0-9 A-Z` without `I L O U`), fixed width, zero-padded.
  Case-insensitive; `I`/`L` read as `1`, `O` reads as `0`.
- **Every media work has one home franchise.** A work created without one gets its own new franchise;
  later sequels join it.
- **Characters, people and companies are global.** A character appearing in another franchise
  (crossovers, "popular characters" spin-offs) is an appearance in the relationship layer, not part of
  the address.
- **Franchise relationships are not addresses.** "Persona is a spin-off of Shin Megami Tensei" lives in
  the relationship layer; franchise addresses stay flat.
- **Numbers are never reused**, even after a move or delete (`core.address_counter`).
- **Moving a work to another franchise** gives it a new number there. The old address of the work and
  of every descendant goes into `core.address_redirect` and keeps resolving.

### Kind codes and widths

The first character of a code is the family: `0` media, `1` child, `2` world.

| Code | Kind | Family | Numbered per | Width | Capacity | Added in |
|---|---|---|---|---|---|---|
| 01 | Anime | media | home franchise | 3 | 32,768 | 0001 |
| 02 | Manga | media | home franchise | 3 | 32,768 | 0001 |
| 03 | Light Novel | media | home franchise | 3 | 32,768 | 0001 |
| 04 | Game | media | home franchise | 3 | 32,768 | 0001 |
| 05 | Series | media | home franchise | 3 | 32,768 | 0001 |
| 06 | Movie | media | home franchise | 3 | 32,768 | 0001 |
| 11 | Season | child | parent | 2 | 1,024 | 0001 |
| 12 | Episode | child | parent | 3 | 32,768 | 0001 |
| 13 | Volume | child | parent | 3 | 32,768 | 0001 |
| 14 | DLC | child | parent | 3 | 32,768 | 0001 |
| 15 | Release | child | parent | 3 | 32,768 | 0001 |
| 16 | Cut | child | parent | 2 | 1,024 | 0001 |
| 17 | Soundtrack | child | parent | 2 | 1,024 | 0001 |
| 19 | Age Rating | child | parent (its system) | 2 | 1,024 | 0003 |
| 21 | Franchise | world | global | 4 | 1,048,576 | 0001 |
| 22 | Character | world | global | 4 | 1,048,576 | 0001 |
| 23 | Person | world | global | 5 | 33,554,432 | 0001 |
| 24 | Company | world | global | 4 | 1,048,576 | 0001 |
| 27 | Genre | world | global | 3 | 32,768 | 0003 |
| 28 | Tag | world | global | 3 | 32,768 | 0003 |
| 29 | Age Rating System | world | global | 2 | 1,024 | 0003 |

Reserved, not built: `25` Outlet; `26` Platform Family and `18` Platform (layer 5).
Changing a width later changes existing addresses; old ones would need redirects.

### Placements

Which child kinds may sit under which parents (`core.entity_kind_parent`). Adding a placement is one row.

| Child | Allowed parents |
|---|---|
| Season | Anime, Series |
| Episode | Anime, Season |
| Volume | Manga, Light Novel |
| DLC | Game |
| Release | Game, Movie |
| Cut | Movie |
| Soundtrack | Anime, Manga, Light Novel, Game, Series, Movie, Season, Episode, Volume, DLC, Release, Cut, Franchise |
| Age Rating | Age Rating System |

A series episode therefore always sits in a season; an anime episode may sit in the anime or in a season.

### What the database enforces

| Rule | Constraint |
|---|---|
| A kind's family, scope and code are consistent | `entity_kind_*_ck`, `entity_kind_code_uq` |
| Only child kinds appear as children in placements | `entity_kind_parent_child_fk` |
| An entity's family and scope match its kind | `entity_shape_fk` |
| Media works have a home franchise; nothing else does | `entity_franchise_scope_ck` |
| The home franchise is a real franchise | `entity_home_franchise_fk` |
| Child kinds have a parent; nothing else does | `entity_parent_scope_ck` |
| The placement is allowed | `entity_parent_allowed_fk` |
| Numbers are unique in their scope | `entity_seq_global_uq`, `entity_seq_franchise_uq`, `entity_seq_parent_uq` |
| A type row matches its entity's kind; a kind cannot change while a type row exists | `<kind>_entity_fk` |
| An entity with children cannot be deleted | `entity_parent_fk` (RESTRICT) |
| A franchise that is still someone's home cannot be deleted | `entity_home_franchise_fk` (RESTRICT) |
| Deleting an entity removes its type row | `<kind>_entity_fk` (CASCADE) |

Not enforceable declaratively: "an entity has its type row". `core.create_entity` guarantees it,
so **create entities only through `core.create_entity`**.

### Functions

| Function | Purpose |
|---|---|
| `core.create_entity(kind, franchise_id, parent_id)` | Creates entity + type row; creates an own franchise for a media work without one |
| `core.address(id)` | Canonical address. `VOLATILE` so it sees rows created earlier in the same statement |
| `core.resolve(path)` | Address → `(entity_id, canonical, redirected)`. Malformed or unknown input returns no row |
| `core.move_to_franchise(id, franchise_id)` | Moves a media work; records redirects for it and all descendants |
| `core.allocate_seq(kind, owner)` | Next never-reused number; refuses when the width is exhausted |
| `core.b32_encode(n, width)`, `core.b32_decode(text)` | Crockford base32 |

### Adding things later

- **New kind:** a row in `core.entity_kind`, a type table in the schema named after its family, and
  placement rows if it is a child kind.
- **New placement:** a row in `core.entity_kind_parent`.

---

## Layer 2 — Primary media

### Shared value types

| Type | Rule |
|---|---|
| `core.labels` | `{"en": {"text": "TV", "native": false}, "ja": {"text": "テレビ", "native": true}}`. At least one language, any language tag. Each entry has non-empty `text` and a `native` true/false; at most one entry is native. A refusal names the broken rule |
| `core.partial_date` | `YYYY`, `YYYY-MM` or `YYYY-MM-DD`; must be a real calendar date. `COLLATE "C"`, so it sorts as plain characters |
| `core.seconds` | Positive whole seconds |

- `core.label_en(text)` builds a one-language English label.
- `core.partial_date_ordered(start, end)` compares at the coarser precision: start `2006-07-13` with
  end `2006` is fine, end `2005-12` is not.

### Option lists

Each option list is a table of `code` (lowercase), `labels` and `sort_order`. Adding an option is a row.

| Table | Options |
|---|---|
| `media.work_status` | upcoming, announced, airing, publishing, early_access, released, finished, hiatus, cancelled |
| `media.source_type` | original, manga, web_manga, light_novel, web_novel, novel, visual_novel, game, anime, series, movie, other |
| `media.anime_format` | tv, ova, ona, movie, special, music_video, short |

Which statuses each medium may use (`media.work_status_kind`, one row per pair):

| Medium | Statuses |
|---|---|
| Anime, Series | upcoming, airing, finished, hiatus, cancelled |
| Manga, Light Novel | upcoming, publishing, finished, hiatus, cancelled |
| Game | announced, early_access, released, cancelled |
| Movie | announced, released, cancelled |

### `media.work` — fields every medium shares

One row per media entity; `kind` says which medium.

| Column | Meaning |
|---|---|
| `status` | Must be allowed for the kind. `NULL` = not set |
| `start_date`, `end_date` | Aired / published / released. Partial dates; end not before start |
| `source_type` | What the work is based on |

- The row is created by the trigger `entity_media_work` whenever a media entity is inserted, and
  backfilled for media entities that existed before migration 0002.
- Its `(entity_id, kind)` key also blocks changing the entity's kind.

### Type-specific fields

| Table | Columns |
|---|---|
| `media.anime` | `format`, `episode_count`, `typical_runtime_s` |
| `media.manga` | `volume_count`, `chapter_count` |
| `media.light_novel` | `volume_count` |
| `media.game` | `local_players_min`, `local_players_max`, `online_players_min`, `online_players_max` (0 = mode not supported) |
| `media.series` | `episode_count`, `typical_runtime_s` |
| `media.movie` | `runtime_s` |

Counts are declared totals, not counted from child pages, because not every episode or volume will
have a page. `NULL` = unknown.

### Release schedules

`media.cadence_period` rows attach to an anime, manga, light novel, series or season. Each row has:

| Column | Meaning |
|---|---|
| `schedule_type` | `regular`, `irregular` or `batch` |
| `item` | What is released: `episode`, `chapter` or `volume` |
| `item_count`, `period_count`, `period_unit` | `item_count` per `period_count` `period_unit` (day, week, month, quarter, year) |
| `starts_on`, `ends_on` | When this schedule applied; a work can have several over time |
| `weekday`, `local_time`, `time_zone` | Optional slot. ISO weekday (1 = Monday); IANA time zone, required with a time |
| `note` | Free text |

Shape rules come from `media.schedule_type`, so a new schedule type is a row:

| Type | Count | Period |
|---|---|---|
| regular | required | required |
| irregular | forbidden | forbidden |
| batch | required (released at once) | forbidden |

Which items each kind may schedule (`media.cadence_item_kind`):

| Item | Kinds |
|---|---|
| episode | Anime, Series, Season |
| chapter | Manga, Light Novel |
| volume | Manga, Light Novel |

PLANNING.md's examples as stored rows (`item_count` / `period_count` / `period_unit`):

| Display | Stored |
|---|---|
| Weekly | 1 / 1 / week |
| Per 2 weeks | 1 / 2 / week |
| 2 per week | 2 / 1 / week |
| Monthly | 1 / 1 / month |
| 2 per month | 2 / 1 / month |
| Per 2 months | 1 / 2 / month |
| Quarterly | 1 / 1 / quarter |
| Yearly | 1 / 1 / year |
| 3 per 2 months | 3 / 2 / month |

Turning a row into words ("Weekly", "Haftalık") is the backend's job, per language.

### What the database enforces

| Rule | Constraint |
|---|---|
| Labels are well-formed | `labels_ck` (message names the rule) |
| Partial dates are real dates | `partial_date_ck` (message names the rule) |
| Option codes are lowercase | `<list>_code_ck` |
| Status pairs only name media kinds | `work_status_kind_kind_fk` |
| One `media.work` row per media entity, matching its kind | `work_pkey`, `work_entity_fk`, `work_kind_family_fk`, `work_family_ck` |
| Status allowed for the medium | `work_status_allowed_fk` |
| End date not before start date | `work_dates_order_ck`, `cadence_dates_order_ck` |
| Known source type / anime format | `work_source_type_fk`, `anime_format_fk` |
| Counts not negative; runtimes positive | `*_count_ck`, `seconds_ck` |
| Player min not above max | `game_local_players_range_ck`, `game_online_players_range_ck` |
| Schedule numbers match the schedule type | `cadence_shape_fk`, `cadence_period_pair_ck` |
| Schedule item allowed for the kind | `cadence_item_allowed_fk` |
| Valid weekday; time needs a zone; zone exists | `cadence_weekday_ck`, `cadence_time_needs_zone_ck`, `cadence_time_zone_ck` |
| Schedules and work rows go when their entity is deleted | `cadence_entity_fk`, `work_entity_fk` (CASCADE) |

---

## Layer 3 — Reusable systems

### Shared value types

| Type | Rule |
|---|---|
| `core.lang_tag` | Language tag: `en`, `ja`, `tr`, `ja-Latn` (romaji), `pt-BR` … |
| `core.country_code` | ISO 3166-1 alpha-2, uppercase: `JP`, `TR`, `US`, `EU` |

### Titles — `core.title`, for every entity

Names of people, characters, companies, genres, tags and age ratings live here too.

| Column | Meaning |
|---|---|
| `lang` | Language of the title |
| `title_type` | `full`, `short`, `alternative` (option list `core.title_type`) |
| `text` | The title |
| `native` | The title in the original language |
| `preferred` | Shown for this language and type when there are several |
| `romanizes_id` | A romanized title points to the title it spells out |
| `sort_order` | Order among titles |

- **At most one native title per type** per entity (one native full, one native short).
- **At most one preferred title** per language and type.
- **A romanization** uses a Latin-script tag (`ja-Latn`), belongs to the same entity and type as its
  source, is never native, and cannot point at itself. A title that a romanization points to cannot be
  deleted on its own; deleting the whole entity removes both.
- **The same text** cannot repeat for one language and type.
- **A published entity must have at least one title.** This is checked at commit, so one transaction
  can create an entity, publish it and add its title in any order, or replace its only title.
- **Search:** trigram index (`pg_trgm`). Tested with a typo (`toradra`) and a Japanese substring (`らドラ`).

### Texts — `core.entity_text`, for every entity

One text per entity, text type and language. Text types (`core.text_type`): `synopsis`, `description`.

### Genres and tags

Genres (`27`) and tags (`28`) are entities: names and aliases are titles, descriptions are texts.

- **Trees:** `core.genre_parent` and `core.tag_parent` allow zero or more parents
  (RPG › Action RPG › Souls-like; Action RPG may also sit under Action). Genres only under genres,
  tags only under tags.
- **No loops:** `core.trg_edge_no_loop(child column, parent column)` refuses an edge that would close a
  loop, on insert and update. It works for any edge table.
- **Descendants:** `core.genre_with_descendants(id)` and `core.tag_with_descendants(id)` return the
  genre or tag plus everything below it, for "filter by genre including sub-genres".
- **Attaching:** `core.entity_genre`, `core.entity_tag` — primary media only (PLANNING.md).
- **Deleting:** a genre or tag still attached to a work, or still a parent, cannot be deleted.
  Deleting a work removes its links; deleting a leaf genre removes its own parent links.

### Age ratings

- **Age Rating System** (`29`, `world.age_rating_system`): `regions` it covers.
- **Age Rating** (`19`, `child.age_rating`) sits under its system: `min_age` 0–99 (optional).
- Name, description, logo and icon come from titles, texts and images.
- **`core.entity_age_rating`:** an entity carries **at most one rating per system**. `system_id` is filled
  from the rating when omitted, and must match the rating's own system.
- Allowed on primary media and on Season, Episode, Volume, DLC, Release, Cut and Soundtrack
  ("releases or child entities when needed").
- A rating in use cannot be deleted; a system with ratings cannot be deleted.

### Images — `core.image`, for every entity

| Column | Meaning |
|---|---|
| `image_type` | Option list `core.image_type`: cover, poster, banner, backdrop, box_art, logo, thumbnail, volume_cover, season_poster, portrait, icon |
| `sha256`, `format` | The file: `<sha256>.<format>`. Formats are an option list `core.image_format` (jpg, png, webp, avif, gif, svg) with their MIME types |
| `width`, `height`, `byte_size` | Width and height together, or neither (vector images) |
| `lang`, `region` | Language of text in the image; region-specific artwork |
| `caption` | Multilingual caption (`core.labels`) |
| `sort_order`, `is_primary` | Order; one primary image per type per entity |

- The same file can be used by several entities, but only once per entity and type.
- Any image type may be used on any entity. The folder the files live in is decided at deployment.

### Role lists (used by layer 4 credits)

Option tables; adding a custom role is a row. PLANNING.md sets no per-kind limits, so any role can be
used on any media or child entity.

| Table | Options |
|---|---|
| `core.staff_role` | director, writer, composer, character_designer |
| `core.company_role` | animation_studio, developer, publisher, production_company, distributor, licensor, broadcaster, original_network, localization_publisher, imprint |
| `core.appearance_role` | protagonist, main, supporting, antagonist, playable, boss, guest |
| `core.performance_type` | voice, live_action, motion_capture |

### Original languages and countries of origin

`core.entity_original_language` (language tags) and `core.entity_origin_country` (country codes),
each with a sort order. Primary media only.

### Where attachable systems apply — `core.attach_kind`

One row per (system, kind). Extending a system to another kind is a row.

| System | Kinds |
|---|---|
| `genre`, `tag`, `origin` | Anime, Manga, Light Novel, Game, Series, Movie |
| `age_rating` | the six media + Season, Episode, Volume, DLC, Release, Cut, Soundtrack |

### What the database enforces

| Rule | Constraint |
|---|---|
| Language tags and country codes are well-formed | `lang_tag_ck`, `country_code_ck` |
| One native title per type; one preferred per language and type | `title_native_uq`, `title_preferred_uq` |
| Romanization: same entity and type, Latin script, not native, not itself | `title_romanizes_fk`, `title_romanization_latin_ck`, `title_romanization_not_native_ck`, `title_romanizes_self_ck` |
| No blank or duplicate titles; known title type | `title_text_ck`, `title_text_uq`, `title_type_fk` |
| Published entities have a title (at commit) | triggers `entity_publish_needs_title`, `title_removal_keeps_one` |
| One text per entity, type and language; not blank | `entity_text_pkey`, `entity_text_body_ck` |
| Genre/tag trees: right kinds, no self, no loops | `genre_parent_*_fk`, `tag_parent_*_fk`, `*_self_ck`, triggers `*_parent_no_loop` |
| Genres, tags, origins, age ratings only on allowed kinds | `entity_genre_allowed_fk`, `entity_tag_allowed_fk`, `entity_original_language_allowed_fk`, `entity_origin_country_allowed_fk`, `entity_age_rating_allowed_fk` |
| A genre/tag in use or with children is not deleted | `entity_genre_genre_fk`, `entity_tag_tag_fk`, `genre_parent_parent_fk`, `tag_parent_parent_fk` (RESTRICT) |
| One age rating per system; rating matches its system | `entity_age_rating_pkey`, `entity_age_rating_rating_fk` |
| Minimum age 0–99 | `age_rating_min_age_ck` |
| Image file, size and format rules; one primary per type | `image_sha256_ck`, `image_size_pair_ck`, `image_width_ck`, `image_height_ck`, `image_format_fk`, `image_file_once_uq`, `image_primary_uq` |

---

## Layer 4 — Relationships, membership, appearances and credits

### Relationship types — `core.relation_type`

A link is stored once: (source) is *type* (target). The type carries the label each side shows, so
the page wording is derived rather than stored twice.

| Column | Meaning |
|---|---|
| `target_labels` | shown on the source's page, naming the target |
| `source_labels` | shown on the target's page, naming the source |
| `two_sided` | same label both ways; stored in one direction only (`symmetric` is a reserved word in SQL) |

Stored "B is `sequel_of` A":

| Page | Shows |
|---|---|
| B | A — Prequel |
| A | B — Sequel |

Seeded from PLANNING.md: sequel, side story, spin-off, adaptation, retelling, recap, remake, reboot,
remaster, port, enhanced version, alternative version, version, re-edit, alternative universe
(two-sided), crossover (two-sided). Adding a type is a row.

### Relationships between works — `core.media_relation`

- Both ends are media works; cross-media is allowed (an anime adapting a light novel).
- No self-links. A pair holds each type once, whichever way round it was entered. Two-sided types are
  stored with the lower id first.
- `two_sided` is filled from the type by a trigger, so a row cannot disagree with its type.
- `note` carries things like "adapts volumes 1–5".
- Deleting a work removes its links.

### Relationships between franchises — `core.franchise_relation`

Same type list and same rules, between franchises (Persona as a spin-off of Shin Megami Tensei).

### Franchise membership — `core.entity_franchise`, view `core.entity_franchise_all`

PLANNING.md: media can belong to franchise**s**. Every work has one **home** franchise, which its
address is built from (layer 1); further franchises are rows in `core.entity_franchise`. The home
franchise cannot be repeated there, and the view lists home and extra together. A franchise that
still has members cannot be deleted.

### Appearances — `core.appearance`, `core.appearance_role_link`

A character in a target (media work or child entity), once per pair, with one or more roles from
`core.appearance_role` (Protagonist, Main, Playable, Boss …), plus a note and sort order.

### Performances — `core.performance`

Person + character + target + performance type + optional language and notes, as PLANNING.md
specifies. Performances are their own system, not tied to an appearance row. Unique per person,
character, target, type and language, with a missing language counted as a value.

### Staff and company credits — `core.staff_credit`, `core.company_credit`

Person or company + role + target (media work or child entity) + note + sort order. One person can
hold several roles on one target; each role is its own row.

### Where these attach — `core.attach_kind`

| System | Kinds |
|---|---|
| `relation`, `franchise` | the six media |
| `appearance`, `credit` | the six media + Season, Episode, Volume, DLC, Release, Cut, Soundtrack |

### What the database enforces

| Rule | Constraint |
|---|---|
| A two-sided type uses the same label on both sides | `relation_type_two_sided_labels_ck` |
| Links are between allowed kinds | `media_relation_source_allowed_fk`, `media_relation_target_allowed_fk` |
| Franchise links are between franchises | `franchise_relation_source_kind_ck`, `franchise_relation_source_fk` |
| Nothing links to itself | `media_relation_self_ck`, `franchise_relation_self_ck` |
| One link per pair and type, either way round | `media_relation_uq`, `media_relation_pair_uq`, `franchise_relation_uq`, `franchise_relation_pair_uq` |
| Two-sided links are stored one way only | `media_relation_two_sided_order_ck`, `franchise_relation_two_sided_order_ck` |
| The two-sided flag matches the type | `media_relation_type_fk`, `franchise_relation_type_fk` + fill trigger |
| The home franchise is not repeated as membership | trigger `entity_franchise_not_home` |
| A franchise with members is not deleted | `entity_franchise_franchise_fk` (RESTRICT) |
| A character appears once per target; roles come from the list | `appearance_uq`, `appearance_role_link_role_fk` |
| Only characters appear; only people perform and are credited; only companies take company roles | `appearance_character_fk`, `performance_person_fk`, `staff_credit_person_fk`, `company_credit_company_fk` |
| One performance per person, character, target, type and language | `performance_uq` (NULLS NOT DISTINCT) |
| One credit per person or company, role and target | `staff_credit_uq`, `company_credit_uq` |
| Deleting an entity removes its links, appearances, performances and credits | `*_fk` (CASCADE) |

---

## Layer 5 — Child entities and platforms

### Platforms

**Platform Family** (`26`, world) holds **Platforms** (`18`, child of its family): PlayStation is
`/26/01` and PS2 is `/26/01/18/01`. A platform has release and discontinuation dates, gets its own
page, and is **not rateable**. A platform still used by a release cannot be deleted.

### Every child type table accepts an empty row

`core.create_entity` inserts the type row empty and the fields are filled afterwards, so no child type
table may demand a value at creation time. A "a season needs a number or a display name" rule was
written and removed for exactly this reason: it made seasons impossible to create. Being identifiable
before going public is already covered by layer 3's rule that a published entity needs a title.

### Fields

| Table | Columns | PLANNING.md |
|---|---|---|
| `child.season` | `number`, `display_name`, `started_on`, `ended_on` | "number/display name … dates"; non-numeric and special seasons work |
| `child.episode` | `number_in_season`, `number_overall` (halves allowed, for 12.5 specials), `aired_on`, `runtime_s`, `source_coverage` | Anime and Series sections |
| `child.volume` | `number` (halves), `released_on`, `page_count`, `chapter_from`, `chapter_to`, `contents` | "number … release dates, ISBNs … page count, chapter range" |
| `child.volume_isbn` | several ISBNs per volume, ISBN-10 or ISBN-13, digits only | "ISBNs" |
| `child.dlc` | `category`, `released_on` | "modular DLC categories rather than a fixed enum" |
| `child.release` | `release_type`, `region`, `released_on`, `platform_id`, `distribution` | "platform, region, release date … physical/digital"; "modular release type" |
| `child.release_language` | languages of a release, with notes like "subtitles only" | "languages" |
| `child.cut` | `cut_type`, `runtime_s`, `changes` | "type, runtime … changed/additional content" |
| `child.soundtrack` | `released_on`, `runtime_s` | "release dates … runtime" |

Titles, covers and synopses come from layer 3; publishers, distributors, composers, performers and
labels are credits from layer 4; age ratings attach from layer 3; store links are layer 7.

### Tracks and themes

Tracks are rows, not entities — no address and no page of their own, as the document asks. A track has
a disc number, a track number, a multilingual title (so Japanese and romaji both fit) and a runtime.
Track numbers are unique per soundtrack and disc, with "no disc number" counted as a value.

`child.episode_theme` links a track to an episode as its opening, ending, insert song or theme.

### Option lists added

`media.dlc_category`, `media.release_type`, `media.distribution`, `media.cut_type`,
`media.theme_type`, plus the `performer` staff role and `label` company role that the soundtracks
section implies.

### What the database enforces

| Rule | Constraint |
|---|---|
| A platform sits under a platform family | `entity_parent_allowed_fk` |
| A platform is not discontinued before release | `platform_dates_order_ck` |
| Seasons and episodes: numbers not negative, dates in order, real dates | `season_number_ck`, `season_dates_order_ck`, `episode_number_*_ck`, `partial_date_ck` |
| A season's display name is not blank | `season_display_name_ck` |
| Volume chapter ranges run forwards; page counts are positive | `volume_chapter_range_ck`, `volume_page_count_ck` |
| ISBNs are 10 or 13 digits, unique per volume | `volume_isbn_format_ck`, `volume_isbn_pkey` |
| DLC categories, release types, distribution and cut types come from their lists | `dlc_category_fk`, `release_release_type_fk`, `release_distribution_fk`, `cut_cut_type_fk` |
| A release's platform is a platform, and cannot be deleted while used | `release_platform_fk` (RESTRICT) |
| A release lists each language once | `release_language_pkey` |
| Track numbers are unique per soundtrack and disc | `soundtrack_track_uq` (NULLS NOT DISTINCT) |
| Themes attach to episodes only, with a known type | `episode_theme_episode_fk`, `episode_theme_type_fk` |
| Deleting an entity removes its ISBNs, languages, tracks and themes | `*_fk` (CASCADE) |

---

## Decided, not built yet

- **Outlet** (magazines, web platforms such as Weekly Shōnen Jump, Shōnen Jump+, Narō): a world kind
  with its own page and serialization history. Agreed; later.
- **Rateable flag per kind:** needed by layer 6 so ratings only attach where they make sense
  (platforms, genres, tags and age ratings: no).

---

## Testing

`db/test.sh` starts a throwaway PostgreSQL 16 container (podman, or `CONTAINER=docker`). For each
`db/tests/NNNN_*.sql` it creates a fresh database, applies migrations `0001..NNNN`, runs the file,
and prints every result. The container is removed at the end.

Every expected refusal must be refused by the **named** constraint or message; a refusal for any other
reason counts as a failure.

---

## Pending layers

6. Aey layer — −50..+50 ratings, subratings, Aey's Take, progress and history
7. External data — MAL, IMDb and other scores and links
