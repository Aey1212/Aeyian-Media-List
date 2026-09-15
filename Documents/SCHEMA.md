# Aeyian Media List — Database Schema

Status (2026/09/15): **Layers 1–2 written and tested** (`db/migrations/0001_core_entity.sql`,
`db/migrations/0002_media_work.sql`; `db/test.sh`: 73 + 94 = 167 passed, 0 failed).
Layers 3–7 not started.

## Engine and modules

PostgreSQL 16. Picked for modularity: each layer lives in its own schema, reusable types are
declared once as domains, and `ALTER TABLE` can evolve existing tables without rebuilding them.

| Schema  | Holds |
|---------|-------|
| `core`  | Entity foundation, kinds, addressing, shared value types |
| `media` | Anime, Manga, Light Novel, Game, Series, Movie; `media.work`; option lists; release schedules |
| `child` | Season, Episode, Volume, DLC, Release, Cut, Soundtrack |
| `world` | Franchise, Character, Person, Company |

Later layers add their own schemas (for example `aey` and `ext`).

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

| Code | Kind | Family | Numbered per | Width | Capacity |
|---|---|---|---|---|---|
| 01 | Anime | media | home franchise | 3 | 32,768 |
| 02 | Manga | media | home franchise | 3 | 32,768 |
| 03 | Light Novel | media | home franchise | 3 | 32,768 |
| 04 | Game | media | home franchise | 3 | 32,768 |
| 05 | Series | media | home franchise | 3 | 32,768 |
| 06 | Movie | media | home franchise | 3 | 32,768 |
| 11 | Season | child | parent | 2 | 1,024 |
| 12 | Episode | child | parent | 3 | 32,768 |
| 13 | Volume | child | parent | 3 | 32,768 |
| 14 | DLC | child | parent | 3 | 32,768 |
| 15 | Release | child | parent | 3 | 32,768 |
| 16 | Cut | child | parent | 2 | 1,024 |
| 17 | Soundtrack | child | parent | 2 | 1,024 |
| 21 | Franchise | world | global | 4 | 1,048,576 |
| 22 | Character | world | global | 4 | 1,048,576 |
| 23 | Person | world | global | 5 | 33,554,432 |
| 24 | Company | world | global | 4 | 1,048,576 |

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
| `core.labels` | `{"en": {"text": "TV", "native": false}, "ja": {"text": "テレビ", "native": true}}`. At least one language, any language tag (`en`, `tr`, `ja`, `ja-Latn` …). Each entry has non-empty `text` and a `native` true/false; at most one entry is native. A refusal names the broken rule |
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

Not in this layer: networks, publishers and imprints are company roles (layer 4); which volumes an
adaptation covers belongs to the adaptation relationship (layer 4); estimated playtimes are external
data (layer 7).

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

## Decided, not built yet

- **Outlet** (magazines, web platforms such as Weekly Shōnen Jump, Shōnen Jump+, Narō): a world kind
  with its own page and serialization history. Agreed; later.
- **Platform Family → Platform** (PlayStation → PS2): entities with their own addresses and pages,
  a platform sitting under its family. **Not rateable.** Built with game releases in layer 5.
- **Rateable flag per kind:** needed by layer 6 so ratings only attach where they make sense
  (platforms: no).

---

## Testing

`db/test.sh` starts a throwaway PostgreSQL 16 container (podman, or `CONTAINER=docker`). For each
`db/tests/NNNN_*.sql` it creates a fresh database, applies migrations `0001..NNNN`, runs the file,
and prints every result. The container is removed at the end.

Every expected refusal must be refused by the **named** constraint or message; a refusal for any other
reason counts as a failure.

---

## Pending layers

3. Reusable systems — titles, genres, tags, roles, images, companies, people
4. Relationship system — directed media relationships, franchise relationships, appearances, staff assignments
5. Child entities — fields for episodes, seasons, volumes, DLC, soundtracks, releases, cuts; platforms
6. Aey layer — −50..+50 ratings, subratings, Aey's Take, progress and history
7. External data — MAL, IMDb and other scores and links
