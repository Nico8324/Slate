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

### Handing off to an acquisition layer

``TitleMetadata/resolveInput`` is `(imdbID, kind, searchNames)` — the shape a
resolver wants, without Slate depending on one. It is `nil` unless some provider
supplied both an IMDb id and a kind, because a resolver cannot ask without them.

``TitleMetadata/searchNames`` is romaji first on purpose: it is what a release
group names a file. The id is not always a bridge, and for Japanese titles that
mapping often does not exist at all — which is the whole reason ``AniListProvider``
is in the first cut.

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

### Seasons

- ``SeasonStructure``
- ``Season``
- ``Episode``
- ``EpisodePosition``
- ``SeasonProvider``

### Handing off

- ``ResolveInput``

### Providers

- ``MetadataProvider``
- ``Snapshot``
- ``TMDBProvider``
- ``AniListProvider``

### Errors

- ``SlateError``
