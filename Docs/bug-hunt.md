# Bug hunt

A standing checklist for logic passes over the package: what each area is, what to look for in
it, and when it was last swept. Tick nothing here — a pass is recorded in the **Swept** table with
its date and commits, and an area comes due again when the code under it has changed a lot since.

## How a pass runs

1. **Pick one to three areas** from *Areas* below, least recently swept or most changed first
   (`git log --since=<last swept> --stat -- <paths>`).
2. **One read-only reviewer per area**, told the files, what was already swept (skip it), and to
   report at most ~10 findings with `file:line`, a concrete title or payload that triggers it,
   confidence, and a minimal fix. No style nits.
3. **Verify every finding against the code** before touching anything; a reviewer is a lead, not
   a verdict. Findings that live in Cinema rather than here go to Cinema's `Docs/bug-hunt.md`.
4. **Fix at the root**, one commit per area, each with its `CHANGELOG.md` entry under Unreleased.
   Non-trivial logic leaves one test behind. Keep the API source-compatible within a minor —
   Cinema pins `upToNextMinor`.
5. **Gate:** `swift test` green before each commit.
6. **Record the pass** in *Swept*, and anything found but deliberately left in *Left open*.
   Release (tag, push, bump Cinema's pin) only after asking.

## Swept

| Date | Area | Commits | Left open |
|---|---|---|---|
| 2026-09-19 | Aggregation and HTTP | `16f3342` | — |
| 2026-09-19 | Ratings | `16f3342` | — |
| 2026-09-19 | Seasons and episode groups | `f98a7fe` | TMDB's `order` semantics unconfirmed against live groups; Cinema should use `absoluteRange(ofSeason:)` in `ShowSeasons` |
| 2026-09-19 | Anime ids and AniList | `f98a7fe` | Cinema builds two `AniListProvider`s (two limiters) and never passes `Lookup.season` |
| 2026-09-19 | Browsing and artwork | `16f3342`, `f98a7fe` | `candidates`/`titles` don't return `total_pages` (TMDB errors past page 500) |

## Areas

Every area uses the same template: where it lives, when it was last swept, and what to check —
for a swept area, the checks are what went wrong there last time, so a re-sweep starts by
confirming none of it came back.

### 1. Aggregation and HTTP
`MetadataAggregator.swift`, `HTTP.swift` (`RateLimiter`, retries, `ResponseCache`), `SlateError`.

**Last swept:** 2026-09-19

- [ ] Later rounds carry what earlier ones learned (ids *and* kind).
- [ ] A failure is said, not read as "nothing": `seasons(for:)` logs why.
- [ ] 5xx after retries is `.http`; only a 429 is `.rateLimited`; 401/403 is `.missingCredential`.
- [ ] A 429 pauses every request through that provider; `Retry-After` in both forms, capped at 60 s.

### 2. Ratings
`Providers/MDBListProvider.swift`, `Ratings`.

**Last swept:** 2026-09-19

- [ ] Every site MDBList returns lands on its own scale (percentages, out of 4, 5, 10), capped at 10.

### 3. Seasons and episode groups
`Seasons.swift` (`SeasonStructure`), `Providers/TMDBProvider+Seasons.swift`.

**Last swept:** 2026-09-19

- [ ] A failed or malformed group request leaves TMDB's own seasons, never nil.
- [ ] Absolute numbers read the same way everywhere: through the provider's numbering
      (`position(ofAbsolute:)`, `absoluteRange(ofSeason:)`), not by walking group seasons.
- [ ] `nativeRange` refuses gaps and repeats; groups number 1…n with specials at 0.
- [ ] Every request that returns names carries `language`.

### 4. Anime ids and AniList
`Providers/AnimeIDBridge.swift`, `Providers/AniListProvider.swift`.

**Last swept:** 2026-09-19

- [ ] TMDB film and show ids are separate maps; the lookup's kind picks one.
- [ ] One bad row doesn't disable the map; the load happens once however many callers.
- [ ] A shared id narrows by TMDB season, then TheTVDB's, and refuses rather than guesses.

### 5. Browsing and artwork
`Providers/TMDBProvider+Browsing.swift`, `TMDBProvider+Artwork.swift`, `Artwork.swift`, `Candidate`.

**Last swept:** 2026-09-19

- [ ] Lists hold each title once; `Candidate.id` is unique across kinds.
- [ ] Artwork prefers the requested locale's language, then no-language, then anything.
