# Aeyian Media List — Planning Document

## Project identity
AML is the personally curated media database at aeyempire.com/AML (desktop) and m.aeyempire.com/AML (mobile). It combines encyclopedia-style information, interconnected entities, external ratings, Aey ratings, and compact Aey's Take opinions. Aey is the sole curator.

## Primary media
- Anime
- Manga
- Light Novel
- Game
- Series (non-anime television/streaming)
- Movie

Soundtracks are proper child/content pages, not a primary medium.

## Design principle: modularity
Prefer reusable entities and relationships whenever a concept may be created, translated, renamed, reused, classified, or linked later. Defaults are useful, but roles, classifications, relationships, languages, rating categories, etc. must remain extensible.

## Shared media architecture
Primary media share: multilingual titles, images, synopsis/description, status, original languages, countries of origin, genres, tags, age ratings, franchises, staff, companies, characters, directed relationships, external links/ratings, Aey ratings, and Aey's Take.

Keep media-specific data in type-specific extensions rather than one huge nullable table.

## Titles
Repeatable multilingual titles support:
- English full/short
- Japanese full/short plus latinized full/short
- unlimited additional languages
- latinization where relevant (any non-Latin script: Japanese, Arabic, etc.)
- potentially multiple legitimate titles per language

## Images
Use modular image assets/types rather than fixed cover/banner fields. Types can include Cover, Poster, Banner, Backdrop, Box Art, Logo, Thumbnail, Volume Cover, Season Poster, etc. Region/language, caption and ordering may be attached.

## Genres
Genres are reusable entities with multilingual names, aliases/short names, descriptions, and zero or more parents. Multiple parents are allowed: use a graph/DAG, not a strict tree.

Example: RPG > Action RPG > Souls-like.

Hierarchical filtering may include descendants.

## Tags
Tags are separate from genres and describe content, themes, mechanics, structures, tropes, settings, etc. They also support multilingual names, aliases, descriptions and multi-parent hierarchy.

## Age ratings
Rating systems are reusable entities containing region, logo and reusable ratings. Individual ratings may have name, icon, optional minimum age and description. Entries may carry multiple systems (PEGI, ESRB, CERO, BBFC, FSK, TV ratings, etc.). Ratings can also attach to releases/child entities when needed.

## Staff
People and roles are separate. A staff assignment connects Person + reusable Staff Role + Target + optional notes. Roles are modular and reusable; defaults can include Director, Writer, Composer, Character Designer, etc., while custom roles remain possible. A person may hold multiple roles on one target. Targets can be media or child entities.

## Companies
Same assignment pattern: Company + reusable Company Role + Target + notes. Example roles include Animation Studio, Developer, Publisher, Production Company, Distributor, Licensor, Broadcaster, Original Network, Localization Publisher, etc.

## Characters and performances
Characters are independent entities. Character appearances connect a Character to a Target with reusable role(s) such as Protagonist, Main, Supporting, Antagonist, Playable, Boss, Guest, etc.

Performances are contextual: Person + Character + Target + performance type + optional language/notes. This handles Japanese/dub VAs, live action, motion capture, alternate actors, different adaptations, etc.

## Franchises
Franchises are proper entities, not tags. Media can belong to franchises and franchises can themselves have directed relationships. Example: Persona can be a spin-off franchise of Shin Megami Tensei.

## Directed media relationships
Relationships are directional and stored once. The UI may derive inverse wording.

Initial extensible vocabulary:
- Prequel / Sequel
- AU
- Spin-off
- Reboot
- Remake
- Remaster
- Retelling
- Adaptation
- Port
- Side Story
- Recap
- Alternative Version
- Crossover
- Enhanced Version
- Version Of
- Re-edit

Cross-media relationships are valid.

Example: if B is stored as SEQUEL_OF A, B displays "Sequel of A" while A can display "Sequel: B" without a second inverse database row.

## External ratings
External rating sources and metrics are modular. Records may contain target, source, metric, score, scale, optional vote count, source URL and recorded date. This supports MAL, AniList, IMDb, Rotten Tomatoes critics/audience, Metacritic, Letterboxd, etc. without dedicated columns.

# Aey rating system
Canonical backend range: -50 through +50.
Frontend numeric range: -10 through +10.
Conversion: frontend score = backend score / 5.

The star visualization represents ten stars of total range: five negative and five positive. Every 5 backend points equals half a star of visual range. Keep the numeric score visible so star rendering does not lose precision.

## General score and subratings
General Score is authoritative and holistic. Subratings are optional modular descriptive dimensions, also -50..+50.

Rules:
- never calculate General Score from subratings;
- never average subratings into General Score;
- no inherent weights;
- no requirement to fill every suggested category;
- medium/genre may suggest categories;
- other qualities not represented by subratings may dominate the General Score.

## Derived favorites
No manual favorite flag. Favorite/ranking sections derive from General Score: top characters, anime, games, episodes, seasons, volumes, DLC, soundtracks, and filtered rankings such as highest-rated Romance Anime.

## Aey's Take
Rateable/linkable targets may contain a short curator opinion displayed as a compact Aey's Take box. It is intentionally not a full blog review.

# Publication / broadcast cadence
Do not hardcode Weekly/Monthly as the data model. Regular cadence uses item_count + period_count + period_unit.

Examples:
- 1 per 1 week -> Weekly
- 1 per 2 weeks -> Per 2 weeks
- 2 per 1 week -> 2 per week
- 1 per 1 month -> Monthly
- 2 per 1 month -> 2 per month
- 1 per 2 months -> Per 2 months
- 1 per 1 quarter -> Quarterly
- 1 per 1 year -> Yearly
- 3 per 2 months -> 3 per 2 months

The number 1 is omitted from human-readable output where natural.

Schedule types: Regular, Irregular, Batch.

Cadence records can have start/end timeframes so publication schedules can change over time. Batch supports simultaneous multi-item/whole-season releases.

# Anime
Anime-specific data can include format (TV, OVA, ONA, Movie, Special, Music Video, Short, etc.), airing status, dates, episode count, typical runtime, broadcast/release data, source/adaptation coverage, and optional season/cour structure.

Child entities: optional Season/Cour, Episode, Soundtrack. Do not force seasons onto anime that do not use them.

Episode pages can contain numbering, titles, air date, runtime, synopsis, thumbnail, staff, characters, opening/ending themes, insert songs, source coverage, external ratings, Aey General Score, subratings and Aey's Take.

# Manga
Manga-specific structure centers on publication and volumes. Publication can include status, dates, cadence periods, publication outlets, and modular company roles.

Child entities: Volume and optional Soundtrack. Individual chapters do not initially need pages.

Volume pages can include number, optional title, covers, release dates, ISBNs, publishers, page count, chapter range/content information, external links, Aey General Score, subratings and Aey's Take.

# Light Novel
Light Novel is its own primary medium. Publication supports status, dates, cadence periods, outlets, publishers, imprints, distributors and localization companies via modular roles.

Child entities: Volume and optional Soundtrack. Chapters do not initially need independent pages.

Volume pages can include number, titles, covers, synopsis, release dates, ISBNs, publishers, page count, contained chapter information, credits, external data, Aey General Score, subratings and Aey's Take.

# Games
Named/distinct works such as Persona 3, Persona 3 FES, Persona 3 Portable and Persona 3 Reload are separate Game entities connected through relationships. Ordinary platform/region releases of one game are release records rather than separate Games.

Game releases can include platform, region, release date, publisher, languages, age ratings, store/external links and physical/digital information.

Platforms are reusable and may have hierarchical/multi-parent organization (PC > Windows/Linux/macOS; PlayStation family, etc.).

Child entities: DLC, Release, Soundtrack. DLC gets proper pages and modular DLC categories rather than a fixed enum.

Gameplay classification should mostly use genres/tags rather than hardcoded booleans. Structured player data may store local/online min/max; tags describe Local Co-op, Online Co-op, PvP, Split Screen, MMO, etc.

External estimated playtimes can be stored as external measurements. Aey's actual playtime is personal data.

Aey game data may include General Score, subratings, play status, progress, dates, playthrough count, actual playtime, platforms played on, and Aey's Take.

# Series
Series means non-anime television/streaming series.

Child entities: Season, Episode, Soundtrack. Seasons are fundamental and have pages.

Season pages can include number/display name, optional title, poster, synopsis, dates, episodes, staff/company assignments, Aey General Score, subratings and Aey's Take. Non-numeric/special seasons must work.

Episode pages can include season episode number, overall number, titles, thumbnail, synopsis, release/air date, runtime, characters, performances/cast, staff, external ratings, Aey General Score, subratings and Aey's Take.

Staff assignments may target the Series, Season, or individual Episode. Series may use cadence records including batch releases.

# Movies
Movies generally lack a season/volume hierarchy but have releases and cuts/editions.

Movie releases can contain region, date, modular release type, distributor, languages and age ratings. Reusable release types can include Theatrical, Festival, Television, Streaming, Home Video, Limited Theatrical, Premiere, etc.

Cuts/editions are normally child entities: Theatrical Cut, Director's Cut, Extended Cut, Unrated Cut, Restored Version, etc. They may contain title, type, runtime, release data, description, changed/additional content, Aey General Score, subratings and Aey's Take.

If the curator judges something to be a genuinely separate work, it may instead be another Movie linked by a directed relationship.

Child entities: Release, Cut/Edition, Soundtrack.

# Soundtracks
Soundtracks are not primary media but have proper pages. They may contain titles, cover, related media/child entity, release dates, composers, performers, label, tracks, runtime, external links, Aey General Score, subratings and Aey's Take.

Individual tracks do not initially require independent pages. Theme/opening/ending/insert songs can be linked contextually to anime/series episodes where appropriate.

# Child/content entities
Current structure:
- Anime: Season/Cour, Episode, Soundtrack
- Manga: Volume, optional Soundtrack
- Light Novel: Volume, optional Soundtrack
- Game: DLC, Release, Soundtrack
- Series: Season, Episode, Soundtrack
- Movie: Release, Cut/Edition, Soundtrack

Many children share titles, images, staff, companies, external data, Aey ratings, subratings and Aey's Take. This suggests a future common linkable/rateable entity layer, but the exact database implementation is not locked yet.

# Current architectural direction
The process deliberately designed each primary medium independently and only then extracted shared systems.

Conceptually:
ENTITY (linkable/rateable)
- Media: Anime, Manga, Light Novel, Game, Series, Movie
- Child Entity: Episode, Season, Volume, DLC, Release, Cut/Edition, Soundtrack
- World Entity: Character, Person, Company, Franchise

Reusable systems attach where applicable: Titles, Images, Genres, Tags, Age Ratings, Aey Ratings, Subratings, Opinions, Staff, Companies, Characters, Relationships and External Data.

After extracting common architecture, the main distinctive structures are:
- Anime: format, episodes/runtime/broadcast structure
- Manga: publication and volumes
- Light Novel: publication and volumes
- Game: platforms, releases, player data, DLC, playtime
- Series: seasons, episodes, television/streaming release structure
- Movie: runtime, releases, cuts/editions

# Planning status
Sufficiently defined for the initial planning stage:
- project identity and six primary media types;
- modular design philosophy;
- multilingual titles and images;
- genres/tags and multi-parent hierarchy;
- age-rating systems;
- modular staff/company roles;
- characters and contextual performances;
- franchises;
- directed/extensible media relationships;
- external ratings;
- Aey's -50..+50 canonical rating system;
- independent modular subratings;
- derived favorites/rankings;
- Aey's Take;
- publication cadence;
- Anime, Manga, Light Novel, Games, Series and Movies;
- child entities and soundtracks.

Next major planning task: convert the conceptual model into a concrete database schema while preserving this modularity.
