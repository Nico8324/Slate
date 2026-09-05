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

The values that lost stay reachable through ``Field/dissent``, but nothing has to
look at them.

### Seasons and episodes

A series is not described by an episode count. TMDB files Bleach as one season of
366 episodes; everybody else counts arcs, and a library filed the flat way lines
up with nothing a person reads or downloads.

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

``TMDBProvider/init(accessToken:language:session:)`` selects the metadata
language. Artwork is deliberately unaffected: every language is fetched and
``ArtworkSet/best(_:preferring:)`` chooses.

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

A provider that fails is not an error either. It lands in
``TitleMetadata/failures`` and the others still answer.

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

### Errors

- ``SlateError``
