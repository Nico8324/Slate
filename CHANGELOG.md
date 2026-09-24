# Changelog

All notable changes to Slate. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.20.0] — 2026-09-24

- Responses persist on disk across launches (`Caches/Slate/<provider>/`, SHA-256 file names,
  TTL from the file date); the anime bridge list is kept on disk and revalidated with ETag.
- Details carry card art (`Snapshot.artwork`, `TitleMetadata.artwork`: viewer's language,
  English and textless), `Snapshot.genreIDs` and `Snapshot.translatedTitles`; `Candidate.popularity`.
- `TMDBProvider.candidate(for:kind:)`: a light lookup by IMDb or TMDB id.
- `TMDBProvider.candidates(correcting:kind:)` and `searchPeople(correcting:)`: spelling-corrected search.
- `Trailer` and `Rating` are `Codable`; `[Trailer].best(version:originalLanguage:viewer:)` picks
  the original, subtitled or dubbed trailer.
- Removed: `ArtworkProvider`, `MetadataAggregator.seasons(for:kind:)` and
  `.artwork(for:kind:nativeSeason:)` — call `TMDBProvider.seasons` / `.artwork` directly.
  AniList's `artwork(for:)` is gone.
- `FieldKey` gains `.artwork`: a `switch` over it with no `default` stops compiling.
- AniList's filtered search pages at most 3 pages, like the unfiltered one.

## [0.19.0] — 2026-09-23

- `TMDBProvider.genres(of:)`, `titles(inGenre:kind:page:)` and `upcoming(_:after:calendar:page:)`.
- `Candidate` gains `releaseDate`, `releasePrecision` (`DatePrecision`), `backdropURL`,
  `originalLanguage` and `genreIDs`; snapshots gain `homeReleaseDate` and `nextEpisode`
  (new `FieldKey` cases).
- Seasons read from the cached details request; the response cache evicts least recently used.

## [0.18.0] — 2026-09-23

- `Person.popularity`, to tell a person from their namesakes.

## [0.17.0] — 2026-09-23

- `TMDBProvider.collection(id:)`: a franchise's films in release order.

## [0.16.0] — 2026-09-23

- Anime charts: `AniListProvider.titles(in:kind:page:perPage:now:)`, `AniListChart`.
- `AnimeIDBridge.broadcastIDs(ofAniList:kind:)`: an AniList work's IMDb/TMDB ids and TMDB season.
- `TMDBProvider.resized(_:toFit:)` replaces any size in the URL, not only `original`.

## [0.15.0] — 2026-09-23

- Charts through MDBList: `MDBListProvider.titles(in:kind:limit:cursor:)`, `OfficialList`, `ListPage`.
- MDBList's key travels as `?apikey=`, the only form it accepts.
- Removed `TraktProvider` and `Provider.trakt`.

## [0.14.0] — 2026-09-23

- Added crew, every trailer with `[Trailer].best(preferring:)`, recommendations, episode
  running times, `TMDBProvider.resized(_:toFit:)`, `seasons(for:kind:)`, configurable
  `cacheTTL` and `clearCache()`, and the Xcode project.
- `trailerYouTubeID` is the original-version trailer; cast lists each person once.
- Many correctness fixes: season caching, conflicts, retries, cache budgets, logging privacy.

## [0.13.0] — 2026-09-20

- TMDB and AniList contribute `ratings` with vote counts; films report `originCountries`.
- Fixes to absolute-number mapping, bridge re-indexing, AniList country, untyped search
  ranking, film-year search and region-scoped lists. Removed `ArtworkKind.still`.

## [0.12.1] — 2026-09-19

- A page past TMDB's last (500) is empty rather than an error; `TMDBProvider.lastPage`.

## [0.12.0] — 2026-09-19

- MDBList scores on the right scale; 401/403 is `.missingCredential`; 429 pauses the provider.
- Season and episode-group fixes; `SeasonStructure.absoluteRange(ofSeason:)`.

## [0.11.0] — 2026-09-11

- `Log`: every silent `nil` says why, with a strict privacy rule (no credentials, no queries).

## [0.10.5] — 2026-09-08

- Documentation only: symbol links and counted claims checked.

## [0.10.4] — 2026-09-08

- Documentation only: README and DocC corrections.

## [0.10.3] — 2026-09-08

- Documentation only: the id bridge and TMDB-only seasons described correctly.

## [0.10.2] — 2026-09-08

- `AnimeIDBridge` logs its load and its refusals.

## [0.10.1] — 2026-09-08

- `AnimeIDBridge` downloads once for concurrent callers; documented as opt-in.

## [0.10.0] — 2026-09-05

- Search, lists and people on `TMDBProvider`: `candidates(for:kind:page:)`, `titles(in:page:)`,
  `person(id:)`, `searchPeople(_:)`, `filmography(personID:)`.
- `updateLanguage(_:)` and `updateRegion(_:)`.

## [0.9.0] — 2026-09-05

- `Relation`, voice actors, `ReleaseStatus` (breaking: `status` was a `String`), AniList studio and tags.

## [0.8.0] — 2026-09-05

- `AnimeIDBridge`, chained resolution rounds, `Lookup.season`, an in-memory response cache.

## [0.7.0] — 2026-09-05

- Watch providers, franchise, keywords, studios, original language, origin country, status,
  air dates, a localised-synopsis fallback, and episode lists.

## [0.6.0] — 2026-09-05

- `MDBListProvider`, `Rating` and `ratings`, a second lookup pass; cast restored.

## [0.5.0] — 2026-09-04

- Removed unused public API (436 lines), including `Candidate`, cast and several conformances.

## [0.4.3] — 2026-09-04

- Documentation only: `nativeSeason` stated on the concrete implementations.

## [0.4.2] — 2026-09-04

- Documentation only: `deduplicatedNames` justified as a fact about names.

## [0.4.1] — 2026-09-04

- `[String].deduplicatedNames` is public; one provider instance per app documented.

## [0.4.0] — 2026-09-04

- `contentRating`, `trailerYouTubeID`, `cast` and `candidates(for:kind:)`.

## [0.3.0] — 2026-09-04

- Pacing, retries, a metadata language, and stubbed request tests; film artwork by IMDb id fixed.

## [0.2.0] — 2026-09-04

- `ArtworkSet` and `Artwork` with per-kind choosing rules, season posters and logos.

## [0.1.2] — 2026-09-04

- Matching fixes from live shows (Suits, Dragon Ball, Hunter x Hunter, `×`) and wider season correction.

## [0.1.1] — 2026-09-04

- `episodeCount` prefers TMDB; `MetadataAggregator.fieldPriority`.

## [0.1.0] — 2026-09-04

- `SeasonStructure`, `Season`, `Episode` and absolute-number translation from TMDB episode groups.

## [0.0.1] — 2026-09-04

- First cut: `MetadataAggregator`, `Field`, `FieldKey`, provenance, `TMDBProvider`, `AniListProvider`.

[0.20.0]: https://github.com/Nico8324/Slate/releases/tag/v0.20.0
[0.19.0]: https://github.com/Nico8324/Slate/releases/tag/v0.19.0
[0.18.0]: https://github.com/Nico8324/Slate/releases/tag/v0.18.0
[0.17.0]: https://github.com/Nico8324/Slate/releases/tag/v0.17.0
[0.16.0]: https://github.com/Nico8324/Slate/releases/tag/v0.16.0
[0.15.0]: https://github.com/Nico8324/Slate/releases/tag/v0.15.0
[0.14.0]: https://github.com/Nico8324/Slate/releases/tag/v0.14.0
[0.13.0]: https://github.com/Nico8324/Slate/releases/tag/v0.13.0
[0.12.1]: https://github.com/Nico8324/Slate/releases/tag/v0.12.1
[0.12.0]: https://github.com/Nico8324/Slate/releases/tag/v0.12.0
[0.11.0]: https://github.com/Nico8324/Slate/releases/tag/v0.11.0
[0.10.0]: https://github.com/Nico8324/Slate/releases/tag/v0.10.0
[0.9.0]: https://github.com/Nico8324/Slate/releases/tag/v0.9.0
[0.8.0]: https://github.com/Nico8324/Slate/releases/tag/v0.8.0
[0.7.0]: https://github.com/Nico8324/Slate/releases/tag/v0.7.0
[0.6.0]: https://github.com/Nico8324/Slate/releases/tag/v0.6.0
[0.5.0]: https://github.com/Nico8324/Slate/releases/tag/v0.5.0
[0.4.3]: https://github.com/Nico8324/Slate/releases/tag/v0.4.3
[0.4.2]: https://github.com/Nico8324/Slate/releases/tag/v0.4.2
[0.4.1]: https://github.com/Nico8324/Slate/releases/tag/v0.4.1
[0.4.0]: https://github.com/Nico8324/Slate/releases/tag/v0.4.0
[0.3.0]: https://github.com/Nico8324/Slate/releases/tag/v0.3.0
[0.2.0]: https://github.com/Nico8324/Slate/releases/tag/v0.2.0
[0.1.2]: https://github.com/Nico8324/Slate/releases/tag/v0.1.2
[0.1.1]: https://github.com/Nico8324/Slate/releases/tag/v0.1.1
[0.1.0]: https://github.com/Nico8324/Slate/releases/tag/v0.1.0
[0.0.1]: https://github.com/Nico8324/Slate/releases/tag/v0.0.1
