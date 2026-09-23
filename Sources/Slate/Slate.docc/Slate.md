# ``Slate``

Ask what a title is, and get an answer that says where each part of it came from.

## Overview

Slate is the *what is this* half of a media library. Give it a name or an IMDb
id; it asks every provider it has at once and returns one ``TitleMetadata`` in
which every field carries both a value and the provider that supplied it.

```swift
let slate = MetadataAggregator(providers: [
    AniListProvider(),
    TMDBProvider(accessToken: token),
    // ``AnimeIDBridge`` and ``MDBListProvider`` are opt-in and in no default
    // set. A provider left out of this list is never asked, and nothing
    // reports its absence.
])

let result = await slate.metadata(for: Lookup(search: "Attack on Titan"))

result.title.best                     // "Shingeki no Kyojin"
result.title.bestProvider             // .aniList
result.overview.value(from: .tmdb)    // TMDB's summary, still there
result.searchNames                    // romaji first
```

The name is the clapperboard — the one object whose whole job is to state what a
piece of footage is before anyone can tell by looking. A studio's *slate* is also
its roster of titles.

### Which decisions live here, and which do not

Slate settles **provider versus provider**. That AniList outranks TMDB for anime
is a fact about AniList and TMDB, not about any particular library, so no
consumer should have to know it. ``Field/best`` is that verdict and
``Field/bestProvider`` names the winner.

Slate does not settle **human versus machine**. Whether a hand-edit outranks a
refresh is a fact about the consuming app's schema and its user, and it belongs
there. ``FieldKey`` is what makes that policy writable as a loop:

```swift
for (field, provider) in result.provenance {
    // "Did a human touch this field, and if not, is `provider` one I accept?"
}
```

This matters more than it sounds. A library that stores merged values behind a
single *this record was edited* flag will, on a refresh from one provider,
silently overwrite a correction that came from another — and it reads as a sync
bug for weeks. Provenance has to be per field, and it is far cheaper to design in
than to retrofit.

The values that lost stay reachable through ``Field/candidates``, which lists
every accepted answer with the winner first. Conflicting matches are excluded
and reported in ``TitleMetadata/failures``.

### Seasons and episodes

A series is not described by an episode count. TMDB files Bleach as one season of
366 episodes; everybody else counts arcs, and a library filed the flat way lines
up with nothing a person reads or downloads.

``MetadataAggregator/seasons(for:)`` asks **TMDB only**, whatever else is in
`providers` — the correction comes out of TMDB's episode groups and has no
equivalent elsewhere.

```swift
let structure = await slate.seasons(for: result.ids)
structure?.ordering                  // .episodeGroup(name: "TVDB Order")
structure?.position(ofAbsolute: 340) // "Bleach - 340" → S14E7
```

``SeasonStructure`` corrects narrowly and says when it has: ``SeasonStructure/ordering``
distinguishes a correction from the ordinary case, and
``SeasonStructure/absoluteNumbering`` distinguishes a correspondence the provider
*stated* from one that was walked. Past the end of a run is left unmapped rather
than clamped.

Correction requires a numbered season of at least 60 episodes, or a sole
numbered season of at least 50. Slate prefers `TVDB Order`, original-air-date
order, then production or television order. The selected group's actual episode
mappings must cover every native numbered episode and divide the longest season.
An incomplete or unavailable group leaves the native structure intact.

### Artwork

A show has forty posters in a dozen languages, and which one is right depends on
who is looking.

```swift
let art = await slate.artwork(for: result.ids, kind: .series)
art.best(.poster, preferring: ["fr", "en"])
art.best(.backdrop)   // textless, for behind a title
```

``ArtworkSet/best(_:preferring:)`` holds the rules, and they differ by kind:
posters and logos follow the viewer's language, while backdrops prefer a
**textless** image outright — it is the one that can sit behind a title without
two sets of words fighting each other. Nothing is chosen for you beyond that.

### Handing off to an acquisition layer

``TitleMetadata/resolveInput`` is `(imdbID, kind, searchNames)` — the shape a
resolver wants, without Slate depending on one. It is `nil` unless some provider
supplied both an IMDb id and a kind, because a resolver cannot ask without them.

``TitleMetadata/searchNames`` is romaji first on purpose: it is what a release
group names a file. The id is not always a bridge, and for Japanese titles that
mapping often does not exist at all — which is the whole reason ``AniListProvider``
is in the first cut.

### What a library record needs

```swift
result.contentRating.best      // "TV-MA", in the region asked for
result.trailerYouTubeID.best   // a key, not a URL
result.cast.best               // billing order, characters, profile images
```

Age ratings are not translations of each other: `TV-MA` has no French
equivalent, France says `16`. ``TMDBProvider`` asks for one region and returns
nothing rather than a rating from a system the viewer does not use.

### A whole library at once

Requests are paced and retried. AniList allows about ninety a minute, and a
corrected show costs three TMDB requests with a fourth for artwork — so a few
hundred titles is well over a thousand requests, and unpaced that arrives as a
wall of 429s that reads as the provider being down. A 429 or 5xx waits the
`Retry-After` the server gave; a 401 is not retried, because an expired
credential will not fix itself. ``SlateError/rateLimited(retryAfter:)`` is
separate from ``SlateError/http(status:body:)`` so "slow down" can be told from
"this will never work".

``TMDBProvider``'s initializer selects the metadata
language. Artwork is deliberately unaffected: every language is fetched and
``ArtworkSet/best(_:preferring:)`` chooses.

### Cache lifetime and refresh

Built-in metadata providers default to a one-hour cache lifetime. The anime ID
bridge defaults to 24 hours. `cacheTTL` is in seconds, bounded to 0…365 days;
zero disables retention and non-finite values use the provider default. Expired
data is fetched on the next lookup. Nothing is persisted to disk.

```swift
let tmdb = TMDBProvider(accessToken: token, cacheTTL: 900)
let slate = MetadataAggregator(providers: [AniListProvider(), tmdb])
await tmdb.clearCache()
let result = await slate.metadata(for: Lookup(imdbID: "tt2560140"))
```

``TMDBProvider/clearCache()`` discards responses and derived season structures.
``AniListProvider/clearCache()`` and ``MDBListProvider/clearCache()`` discard
responses; ``AnimeIDBridge/clearCache()`` discards its index. These methods also
cancel pending requests for that provider. Clearing one provider does not clear
others in an aggregator. Changing TMDB's language or region clears its caches.

Concurrent identical requests share one fetch. Cancelling one waiter leaves the
others running; cancelling the last waiter cancels the fetch. Invalidated work
cannot restore old cache entries. Request headers distinguish credentials and
representations without being logged.

### Matching, validation, and failures

```swift
let result = await slate.metadata(
    for: Lookup(search: "Hunter x Hunter", year: 1999, kind: .series)
)
```

TMDB uses original-release or series-premiere years; AniList checks the work's
start year and format. An exact AniList ID overrides name, year, and kind hints.
Filtered searches continue until a page has a match: at most 500 pages for TMDB
and 100 for AniList. Ranking stays within the first eligible page.

The aggregator rejects answers contradicting an explicit lookup ID. Among
provider answers, general priority decides between conflicting shared IDs or
media kinds. The rejected snapshot contributes no fields or IDs and appears in
``TitleMetadata/failures``. Providers absent from a priority list sort last by
identifier. Release-date differences alone do not establish a conflict between
a cour and a whole series.

Direct provider calls throw credential, HTTP, rate-limit, lookup-validation,
GraphQL, decoding, or transport errors. ``SlateError/graphQL(_:)`` includes an
AniList error returned with HTTP 200; that response is not cached as a no-match.
A valid empty result still means no match. The aggregator records failures as
descriptions and allows other providers to answer. HTTP body details in these
descriptions are not suitable for public logging.

``Identifiers`` omits malformed IMDb IDs and nonpositive numeric IDs at
construction. Lookup validation also checks mutated identifiers, years in
1…9999, and nonnegative seasons. Built-in snapshot construction omits blank
strings, nonpositive runtime and episode counts, and scalar ratings outside
0…10. Release dates must be valid calendar dates rather than rolled-over dates.

### Cancellation

Direct provider calls propagate cancellation. Aggregator methods are
nonthrowing: they stop new enrichment rounds and may return partial results
with failure descriptions. Cancellation is not a signal that a title is absent.

```swift
let task = Task { await slate.metadata(for: Lookup(search: "Dune")) }
task.cancel()
```

### Building and testing

The repository includes `Slate.xcodeproj` with a shared **Slate** scheme, a
framework target, and **SlateTests**. Run `swift test` for the package or
`xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=macOS'`
for the project. Build documentation with Xcode's **Build Documentation** action.
`project.yml` is the XcodeGen specification; run `xcodegen generate` after adding
or removing source files. XcodeGen is not a runtime dependency.

### One request, eight answers

TMDB's `append_to_response` returns availability, keywords, studios, franchise,
translations, credits and certifications for the price of the request already
being made. ``WatchOption`` is scoped to one region and never merged across them;
an empty localised synopsis falls back to English rather than rendering blank.

### Ratings, cross-referenced

``MDBListProvider`` returns IMDb, Metacritic, both tomatometers, Letterboxd,
Trakt and MyAnimeList on one credential. They are kept per site and never
averaged — sites measure different things and disagree usefully. Each ``Rating``
carries its normalised 0…10 value and the site's own scale.

It resolves by id and has no title search, so on a name lookup it stays silent
until TMDB supplies one; ``MetadataAggregator/metadata(for:)`` then asks again
with the ids known.

### Credentials

Slate holds none. ``TMDBProvider`` is constructed with a key it does not source
and rotates it through ``TMDBProvider/updateAPIKey(_:)``; keys travel as
`Authorization: Bearer` and never in a query string. This is a public repository:
nothing in it is a key, and nothing in it should become one.

``AniListProvider`` needs no credential at all.

### What a provider may not do

A provider answers with a ``Snapshot`` of flat optionals and nothing else. It
does not rank itself, does not merge, and does not guess: ``TMDBProvider``
reports ``Snapshot/isAnime`` as `nil` rather than false, because TMDB has no
anime type and its `anime` keyword is volunteer-applied. AniList answering at
all is the signal.

A failed provider is recorded in ``TitleMetadata/failures`` by the aggregator;
other providers still answer. Direct provider calls throw.

## Topics

### Asking

- ``MetadataAggregator``
- ``Lookup``

### The answer

- ``TitleMetadata``
- ``Field``
- ``Attributed``
- ``Provider``
- ``FieldKey``
- ``Identifiers``
- ``Kind``

### Artwork

- ``ArtworkSet``
- ``Artwork``
- ``ArtworkKind``
- ``ArtworkProvider``

### Seasons

- ``SeasonStructure``
- ``Season``
- ``Episode``
- ``EpisodePosition``

### Handing off

- ``ResolveInput``

### Providers

- ``MetadataProvider``
- ``Snapshot``
- ``TMDBProvider``
- ``AniListProvider``
- ``MDBListProvider``
- ``AnimeIDBridge``
- ``Rating``
- ``CastMember``
- ``WatchOption``
- ``Franchise``
- ``Relation``
- ``ReleaseStatus``
- ``Candidate``
- ``Person``
- ``TitleList``

### Errors

- ``SlateError``
