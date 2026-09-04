# Changelog

All notable changes to Slate. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.0.1]: https://github.com/Nico8324/Slate/releases/tag/v0.0.1
