# Changelog

All notable changes to Slate. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-09-04

Television has seasons and episodes. 0.0.1 answered "366 episodes" for Bleach and
called that a description of a series; it was not one.

TMDB files Bleach as a single season of 366 episodes and Detective Conan as one
of 1212. Nothing else in the world numbers them that way — Wikipedia, TheTVDB and
the groups that name the releases all count arcs — so a library filed TMDB's way
lines up with nothing a person reads, searches for, or downloads. The correction
comes from TMDB itself, through `episode_groups`, which is where the community
keeps the orderings TMDB's own numbering isn't.

That means **TheTVDB's ordering without a TheTVDB key**, which is most of the
reason the plan wanted TheTVDB in the first place.

### Added

- **`SeasonStructure`.** How a series is divided, with `ordering` saying whether
  that is the provider's own answer or a correction, and `absoluteNumbering`
  saying whether the correspondence was *stated* by the provider or walked.
- **`Season` and `Episode`.** Arc names, episode titles, air dates, and each
  episode's `native` position so the two numberings stay translatable.
  `Season.episodes` is optional: `nil` means not loaded, which is not the same as
  a season with no episodes.
- **Absolute-number translation.** `position(ofAbsolute:)` turns `Bleach - 340`
  into the season and episode it is shown under; `absolute(ofSeason:episode:)`
  goes back. Past the end of a run is left **unmapped, never clamped** — a number
  beyond the last episode means the season list is incomplete or the show was
  matched wrongly, and filing it somewhere plausible hides that.
- **`nativeRange(ofSeason:)`.** The provider's own episode numbers for one arc,
  when contiguous — Bleach's second arc is TMDB S1 E21–41, and a bounded range is
  what an acquisition can ask an indexer for instead of matching a
  complete-series pack. An ordering that jumps around returns `nil` rather than a
  range quietly covering episodes it does not hold.
- **`SeasonProvider`** and `MetadataAggregator.seasons(for:)`. A separate request
  from `metadata(for:)`, because it is a separate question and several requests
  more expensive.
- **`TMDBProvider.episodes(ofShow:season:)`** for the ordinary path, where
  episodes are not already in hand. The episode-group path fills them for free.
  Orderings are cached for the life of the provider, `nil` results included.

### How narrowly it intervenes

Choosing an ordering is a decision, not a lookup — Bleach carries thirteen and
they disagree with each other — and getting it wrong silently renumbers a
library. So the correction applies only when TMDB is *clearly* flattening (any
season of 60 or more), only towards an ordering that accounts for every episode
the show is said to have, and only by name: `TVDB Order` first, then an
original-air-date ordering. Story-arc orderings are never a fallback; Bleach has
three splitting the same run 21, 12 and 25 ways. Specials keep season 0 rather
than being renumbered into the run.

Ported from Cinema's `ShowSeasons`, `ArcSeasons` and `AbsoluteEpisodeMap`, whose
thresholds were arrived at against real shows: Suits, Rick and Morty, Attack on
Titan, SPY × FAMILY and Frieren are untouched, while Bleach, Detective Conan, One
Piece and Naruto Shippūden are all caught.

### Changed

- **The case against AniDB and TheTVDB is restated, because the old one expired.**
  0.0.1 rejected AniDB on the grounds that episode numbering was solved
  app-side. Slate owns that now, so that argument no longer holds. TheTVDB's
  ordering arrives free through TMDB's episode groups; AniDB's fansub-accurate
  numbering and specials are the one gap that does not close, which makes it the
  most likely next provider rather than a permanent no. The bar is unchanged:
  name a title the current path gets wrong.

## [0.0.1] — 2026-09-04

First cut. Two providers, one credential, and one design decision that the rest
of the package exists to serve: **Slate does not return merged values.**

Every field of `TitleMetadata` carries the provider that supplied it. A library
that stores merged metadata behind a single *this record was edited* flag will,
on a refresh from one provider, silently overwrite a correction that came from
another — and it reads as a sync bug for weeks. Provenance has to be per field,
and it is far cheaper to design in now than to retrofit later.

The split of responsibility, which is the thing to remember: Slate settles
**provider versus provider**, because that AniList outranks TMDB for anime is a
fact about AniList and TMDB. Slate does not settle **human versus machine**,
because whether a hand-edit outranks a refresh is a fact about the consuming
app's schema and its user.

### Added

- **`MetadataAggregator`.** Asks every provider concurrently, orders their
  answers by `priority`, and never throws — a provider that fails lands in
  `TitleMetadata.failures` and the others still answer.
- **`Field<Value>`.** One field's answers, winner first. `best` and
  `bestProvider` are the verdict; `dissent` is what the losers said, reachable
  but never the default read; `value(from:)` asks one provider directly.
- **`FieldKey` and `TitleMetadata.provenance`.** Fields addressable without
  knowing their types, so a consumer can express *"was this field hand-edited,
  and is it machine-owned anyway"* as a loop rather than as one branch per
  field. Thirteen hand-written branches drift apart; a loop does not.
- **`TitleMetadata.resolveInput`.** `(imdbID, kind, searchNames)` — the shape an
  acquisition layer wants, without depending on one. `nil` unless some provider
  supplied both an IMDb id and a kind, since a resolver cannot ask without them.
- **`TMDBProvider`.** The IMDb id, western movies and TV, art, ratings. Actor;
  the v4 read token is injected, rotated through `updateAPIKey(_:)`, and sent as
  `Authorization: Bearer` — never a query string. No key is stored in this
  repository and none should be.
- **`AniListProvider`.** Anime detection, romaji and native names, episode
  counts. **No credential**, which is why it is in the first cut.
- **`Lookup`, `Snapshot`, `MetadataProvider`.** A provider answers with flat
  optionals and nothing else: it does not rank itself, does not merge, and does
  not guess.

### Notes on two deliberate silences

- **TMDB reports `isAnime` as `nil`, not `false`.** TMDB has no anime type and
  its `anime` keyword is volunteer-applied to a fraction of what qualifies.
  AniList answering at all is the signal; a guess dressed as a value is worse
  than an absence.
- **AniList synonyms are filtered to mostly-Latin names.** Romaji, English and
  native Japanese are always kept — trackers do file under the Japanese title —
  but AniList carries the Thai, Hebrew and Arabic name of everything, and a
  resolver that matches by substring gets nothing from them but false hits.

### Not done

Recorded because each was considered on evidence and rejected, and a future
reader deserves the reasoning rather than a re-argument.

- **AniDB.** Its distinctive value is fansub-accurate episode numbering, which
  the consuming app already solves. It is rate-limited and licence-encumbered,
  and an embedded client id in a public repository is a ban waiting to happen.
  The bar for adding it: a *named* title the current path gets wrong.
- **manami.** Maps AniList ↔ MAL ↔ AniDB ↔ Kitsu ↔ anime-planet ↔ livechart, and
  bridges to neither IMDb nor TMDB. Tens of megabytes for ids nothing reads.
- **Fribb / anime-lists.** A different dataset, and it *does* carry the bridge —
  `imdb_id`, `themoviedb_id`, `tvdb_id` alongside `anilist_id`, plus the
  `episode_offset` that absolute-to-season mapping otherwise hand-rolls. So the
  TMDB→AniList id bridge is possible; it is simply not needed yet. Two things to
  know before reopening it: 7.5 MB for the full list, and the mapping is
  many-to-one in the direction we would query it — the first three records
  already show two AniDB entries sharing one `imdb_id` and one `themoviedb_id`.
  An IMDb id resolves to a *set*, so the bridge would still need the
  disambiguation that searching by name does today.
- **Watchmode.** Answers "where can I stream this", which is the question this
  trio exists so nobody has to ask.
- **Trakt scrobbling.** A different app's premise; its ratings duplicate
  MDBList's.
- **TheTVDB, Fanart.tv, MDBList, OMDb.** Each is one more key and one more setup
  step. Add one when a field is missing that a user notices, not before.
- **Per-field provider priority.** Priority is genuinely per-field domain
  knowledge — TheTVDB beats TMDB for episode structure, Fanart beats both for
  logos. With two providers that table has nothing in it. When a third lands,
  `MetadataAggregator.priority` becomes `[FieldKey: [Provider]]` and no caller
  changes.

[0.1.0]: https://github.com/Nico8324/Slate/releases/tag/v0.1.0
[0.0.1]: https://github.com/Nico8324/Slate/releases/tag/v0.0.1
