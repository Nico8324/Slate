# Slate

Metadata aggregation for a media library: given a title, answer *what is this*.

Slate is one third of a trio — **Slate** (what is this) / **CinemaResolvers**
(where do I get it) / **Cinema** (where you watch it). The name is the
clapperboard: the one object whose whole job is to state what a piece of footage
is before anyone can tell by looking. A studio's *slate* is also its roster of
titles.

## The one rule: Slate does not merge

Every field of ``TitleMetadata`` is a ``Field`` holding **every** provider's
answer, ordered by priority — not a merged value:

```swift
let slate = MetadataAggregator(providers: [
    AniListProvider(),
    TMDBProvider(accessToken: token),
])

let result = await slate.metadata(for: Lookup(search: "Attack on Titan"))

result.overview.best                  // highest-priority answer
result.overview.bestProvider          // .aniList
result.overview.value(from: .tmdb)    // what TMDB said, still there
result.searchNames                    // ["Shingeki no Kyojin", "Attack on Titan", …]
```

This exists because of a specific bug. A library that stores merged values and
one "user edited this record" flag will, on a refresh from provider #4, silently
overwrite a hand-correction to a field that provider #1 supplied — and it reads
as a sync bug for weeks. Provenance has to be per field, and it is far cheaper
to design in than to retrofit. Slate holds no policy about which answer wins;
the app decides, because the app is where the edits live.

## Which decisions live where

Slate settles **provider vs provider**: that AniList outranks TMDB for anime is a
fact about AniList and TMDB, so a consumer should never have to know it. That
verdict is `field.best`, and `field.bestProvider` says who won.

Slate does not settle **human vs machine**: whether a hand-edit outranks a
refresh is a fact about the consuming app's schema and its user. `FieldKey` makes
that policy writable as a loop rather than a branch per field:

```swift
for (field, provider) in result.provenance {
    // "Did a human touch this field, and if not, is `provider` one I accept?"
    // — and note some fields are machine-owned even on a hand-edited record.
}
```

The losers stay reachable via `field.dissent`, but nothing has to look at them.

A failing provider is not an error. It lands in `result.failures` and the others
still answer.

## Handing off to an acquisition layer

`result.resolveInput` is `(imdbID, kind, searchNames)` — the shape
`Resolvers.ResolveRequest` wants, without Slate depending on CinemaResolvers.
It is `nil` unless some provider supplied both an IMDb id and a kind, since a
resolver cannot work without them.

`searchNames` is romaji-first on purpose: it is what a release group names a
file. This is the whole reason AniList is here — the id is not always a bridge,
and for Japanese titles that mapping often does not exist at all.

## Credentials

Slate holds none. A provider is constructed with a key it does not source and
rotates it via `updateAPIKey(_:)`; keys are sent as `Authorization: Bearer` and
never in a query string. This is a public repository — nothing in it is a key,
and nothing in it should become one.

`AniListProvider` needs no credential at all.

## Providers

| Provider | Credential | Gives |
| --- | --- | --- |
| TMDB | v4 read token | The IMDb id, western movies and TV, art, ratings |
| AniList | none | Anime detection, romaji/native names, episode counts |

TMDB deliberately reports `isAnime` as *nothing rather than a guess*: it has no
anime type, and its `anime` keyword is volunteer-applied. AniList answering at
all is the signal.

### Deliberately not here

- **AniDB** — its distinctive value is fansub-accurate episode numbering, which
  the consuming app already solves. It is rate-limited and licence-encumbered,
  and an embedded client id in a public repo is a ban waiting to happen. The bar
  for adding it: a *named* title the existing machinery gets wrong.
- **manami** — maps AniList ↔ MAL ↔ AniDB ↔ Kitsu ↔ anime-planet ↔ livechart, and
  bridges to neither IMDb nor TMDB. Tens of megabytes for ids nothing reads.
- **Fribb / anime-lists** — a different dataset, and it *does* carry the bridge:
  `imdb_id`, `themoviedb_id`, `tvdb_id` alongside `anilist_id`, plus the
  `episode_offset` that absolute-to-season mapping otherwise hand-rolls. So an
  id bridge from TMDB to AniList is possible; it is simply not needed yet, and
  the bar is the same as AniDB's — a *named* title the name-search path gets
  wrong. Two things to know before reopening it: 7.5 MB for the full list, and
  the mapping is many-to-one in the direction we would query it. The first three
  records already show it: two different AniDB entries (`3x3 Eyes` and its
  sequel) share one `imdb_id` and one `themoviedb_id`. An IMDb id resolves to a
  *set* of AniList entries, so the bridge would still need the disambiguation
  that searching by name does today.
- **Watchmode** — answers "where can I stream this", the question this trio
  exists so nobody has to ask.
- **Trakt scrobbling** — a different app's premise; its ratings duplicate
  MDBList's.
- **TheTVDB, Fanart.tv, MDBList, OMDb** — each is one more key and one more
  setup step. Add one when a field is missing that a user notices, not before.

## Requirements

Swift 6, strict concurrency complete, macOS/iOS/tvOS/visionOS 26. `Sendable`
value types throughout; no SwiftData, no UI, no `@MainActor` in the API surface.
Mapping these DTOs onto persistent models is the app's job and stays there.
