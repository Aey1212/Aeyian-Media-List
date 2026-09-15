# Aeyian Media List — Database Schema

Status (2026/09/15): **Layer 1 written and tested** (`db/migrations/0001_core_entity.sql`, 73/73 tests).
Layers 2–7 not started.

## Engine and modules

PostgreSQL 16. Picked for modularity: each layer lives in its own schema, reusable types can be
declared once as domains, and `ALTER TABLE` can evolve existing tables without rebuilding them.

| Schema  | Holds |
|---------|-------|
| `core`  | Entity foundation, kinds, addressing |
| `media` | Anime, Manga, Light Novel, Game, Series, Movie |
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

## Testing

`db/test.sh` starts a throwaway PostgreSQL 16 container (podman, or `CONTAINER=docker`), applies every
migration to a fresh database for each `db/tests/*.sql`, prints every result, and stops the container.

Every expected refusal must be refused by the **named** constraint or message; a refusal for any other
reason counts as a failure.

---

## Pending layers

2. Primary media — type-specific fields for Anime, Manga, Light Novel, Game, Series, Movie
3. Reusable systems — titles, genres, tags, roles, images, companies, people
4. Relationship system — directed media relationships, franchise relationships, appearances, staff assignments
5. Child entities — fields for episodes, seasons, volumes, DLC, soundtracks, releases, cuts
6. Aey layer — −50..+50 ratings, subratings, Aey's Take, progress and history
7. External data — MAL, IMDb and other scores and links
