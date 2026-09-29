<div align="center">

# Slate

**What is this?**
A dependency-free Swift package that asks every metadata provider at once and answers with values that each say **where they came from**.

[![Version](https://img.shields.io/badge/version-0.20.1-blue)](CHANGELOG.md)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2026%20%7C%20iOS%2026%20%7C%20tvOS%2026%20%7C%20visionOS%2026-1793D1)](#installation)
[![Dependencies](https://img.shields.io/badge/dependencies-none-success)](#installation)

</div>

Slate turns a name, an IMDb id or a TMDB id into one record whose every field is a
`Field`: the winning value, the provider that won it, and every other provider's answer
still reachable. It also corrects TMDB's flattened anime seasons, chooses artwork and
trailers for a viewer, and browses TMDB, AniList and MDBList charts. Slate settles
*provider versus provider*; whether a hand-edit outranks a refresh is the app's call.

| Package | Question it answers |
| :--- | :--- |
| **Slate** | *What is this?* |
| **CinemaResolvers** | *Where do I get it?* |
| **Cinema** | *Where do I watch it?* |

This README describes release 0.20.1.

## Installation

```swift
.package(url: "https://github.com/Nico8324/Slate.git", from: "0.20.1")
```

```swift
.product(name: "Slate", package: "Slate")
```

macOS, iOS, tvOS and visionOS 26. Swift 6, strict concurrency, no package dependencies.

## Quick usage

Hold one instance of each provider for the life of the app: pacing and caches live there.

```swift
let tmdb = TMDBProvider(accessToken: keychain.tmdbToken,       // injected, never stored
                        language: "fr-FR", region: "FR")
let slate = MetadataAggregator(providers: [
    AniListProvider(),                     // no credential
    tmdb,
    AnimeIDBridge(),                       // opt-in: anime ids from an IMDb or TMDB id
    MDBListProvider(apiKey: keychain.mdbListKey),  // opt-in: ratings from six sites
])

let result = await slate.metadata(for: Lookup(search: "Attack on Titan"))
result.title.best                  // "Shingeki no Kyojin"
result.title.bestProvider          // .aniList
result.overview.value(from: .tmdb) // TMDB's summary, still there
result.searchNames                 // romaji first, for a tracker
result.failures                    // providers that failed; the rest still answered
```

Seasons and artwork are TMDB's alone, so they are asked of `TMDBProvider` directly:

```swift
let kind = result.kind.best ?? .series
let structure = try await tmdb.seasons(for: result.ids, kind: kind)
structure?.position(ofAbsolute: 340)          // "Bleach - 340" → S14E7

let art = try await tmdb.artwork(for: result.ids, kind: kind)  // every language, for a picker
art?.best(.poster, preferring: ["fr", "en"])
art?.best(.backdrop)                          // textless wins
```

Browsing and search, one provider each:

```swift
try await tmdb.candidates(for: "Dragon Ball")          // what a search might have meant
try await tmdb.candidates(correcting: "inceptoin")     // and what was meant when misspelled
try await tmdb.titles(in: .trendingThisWeek)
try await tmdb.upcoming(.movie)
try await AniListProvider().titles(in: .trending, kind: .series)
```

Responses are cached in memory and on disk (`Caches/Slate/`), keyed by request, for
`cacheTTL` seconds; `clearCache()` drops them. `region` picks age ratings, streaming
services and release windows: pass the app's, since Slate never reads the device locale.

## Documentation

The DocC catalog at [Sources/Slate/Slate.docc](Sources/Slate/Slate.docc/Slate.md) covers
the rest: provenance and field priority, seasons and absolute numbering, artwork rules,
the anime id bridge, ratings, credentials, cache lifetime, cancellation, and what a
provider may not do. Build it with:

```sh
xcodebuild docbuild -project Slate.xcodeproj -scheme Slate -destination 'platform=macOS'
```

## Working on Slate

```sh
swift test
xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=macOS'
```

[Slate.xcodeproj](Slate.xcodeproj) is checked in; regenerate it with `xcodegen generate`
after adding or removing source files or changing [project.yml](project.yml). Tests use
canned payloads, never live credentials. Slate holds no keys: this is a public repository.

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.
