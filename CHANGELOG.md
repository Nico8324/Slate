# Changelog

All notable changes to Slate. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.3] — 2026-09-04

Documentation only; behaviour unchanged. Tagged for the same reason 0.4.2 was —
where a warning lives decides whether anyone reads it.

### Changed

- **The `nativeSeason:` coupling is now stated on the concrete implementations**,
  not only on `MetadataAggregator.artwork` and the `ArtworkProvider` protocol. A
  caller holding a `TMDBProvider` directly — which is how the one known consumer
  uses this package — got no parameter documentation at all, because Quick Help
  shows the concrete method's doc rather than the protocol's. The warning existed
  in the two places that caller would not look.

  Passing a corrected season number returns a real picture of the wrong season
  with nothing in the result to say so: Bleach's arc season 2 lives inside TMDB's
  season 1, so asking for 2 returns Thousand-Year Blood War's posters.

- **`AniListProvider.artwork` documents that a non-nil season returns `nil`.**
  AniList files each cour as its own entry and holds no season-level art, so
  refusing is right — but silence about refusing is not.

## [0.4.2] — 2026-09-04

Documentation only; behaviour is unchanged. Tagged rather than left on `main`
because the words *are* the contract, and 0.4.1 shipped the wrong reason for the
right behaviour.

### Changed

- **`deduplicatedNames` is now justified as a fact about names, not about a
  destination.** 0.4.1 said it folded case "because the destinations are
  case-insensitive searches" — which is a fact about a transport, and a published
  contract resting on one is a contract a future maintainer may reasonably
  un-fold for a case-sensitive destination. The real reason is simpler and does
  not depend on anyone's endpoint: capitalisation does not make a different
  title, so `BLEACH` and `Bleach` name one work. Likewise the ordering, which is
  now justified by the order being information the *caller* owns — a romaji-first
  list asserts which name is likeliest — rather than by how one resolver happens
  to consume it.

  The doc now says explicitly that a destination with its own rule needs its own
  fold at its own boundary, and that a package should not skip that on the
  grounds its callers were careful.

## [0.4.1] — 2026-09-04

Additive only, so an `upToNextMinor` pin picks it up without a bump.

### Added

- **`[String].deduplicatedNames` is public.** Three implementations of the same
  primitive existed across the three repositories because nobody could reach this
  one. The published contract is the **ordering**, not the deduplication: a
  resolver that stops at the first name to find anything is choosing by position,
  so the first spelling of a repeated name survives and a romaji-first list stays
  romaji-first. Case-insensitive, because the destinations are case-insensitive
  searches — `BLEACH` and `Bleach` are one question.

  A guard at a package's own boundary is *not* made redundant by this. Deduping
  because the caller was careful is one careless caller away from the bug; this
  publishes the primitive, not a promise about what arrives.

### Documented

- **One provider instance per app.** The request allowance lives in the provider,
  and for `AniListProvider` — a struct holding a reference — copies share it while
  a freshly constructed one gets a new one. `AniListProvider()` per lookup is
  paced against nothing, and the only symptom is 429s arriving later than they
  should have. `TMDBProvider` holds the remembered orderings too.

  Nothing in either type signature said this, and a consumer had to work it out
  from the outside to hold the aggregator statically. Changing it would break a
  caller without a signature moving.

## [0.4.0] — 2026-09-04

The fields a library actually writes to a record, which Slate could not supply.
Reading Cinema's `apply()` — the one known consumer — it sets `name`, `synopsis`,
`yearOfRelease`, `contentRating`, `genres`, `isAnime`, `trailerYouTubeID` and
artwork. Slate covered five of those.

### Added

- **`contentRating`.** Age ratings are **not translations of each other**:
  `TV-MA` has no French equivalent, France says `16`. So
  `TMDBProvider(accessToken:language:region:)` asks for one country and returns
  *nothing* rather than a rating from a system the viewer does not use. Films
  read it from release dates, television from content ratings, and blank
  certifications — TMDB has plenty — are skipped rather than returned as an
  empty rating.
- **`trailerYouTubeID`.** A key, not a URL, because a player wants the id. An
  official trailer wins over an unofficial one, which wins over a teaser, which
  beats a blank space where a preview should be.
- **`cast`.** In billing order, with characters and profile images. Television
  uses aggregate credits, where a role spans a run; films use plain credits.
- **`candidates(for:kind:)`.** What a search might have meant, so a person can
  choose instead of being handed an answer. "Dragon Ball" resolved to Dragon
  Ball Z for as long as nobody could see the alternatives — a picker is the
  cheapest possible fix for that class of bug. People are filtered out of
  `/search/multi` results, since they are not titles.

All three fields arrive in the same request as the rest of the record, through
`append_to_response`. One request, not five.

### Testing

The two suites that share the stub table are nested now: as siblings they ran in
parallel and raced each other's routes, which failed as four unrelated 404s.

## [0.3.0] — 2026-09-04

The things that stop it working on a whole library rather than on the fourteen
titles that were checked by hand.

### Added

- **Pacing.** `RateLimiter` hands out turns in order, so a burst is spread rather
  than dropped: AniList allows about ninety requests a minute, and a corrected
  show costs three TMDB requests with a fourth for artwork. Scanning a few
  hundred titles is well over a thousand requests, and unpaced that arrives as a
  wall of 429s that reads as the provider being down.
- **Retries that respect the server.** 429 and 5xx are retried up to three tries
  total, waiting the `Retry-After` the server gave — it knows when its window
  resets, and guessing shorter just burns the next attempt. Capped at thirty
  seconds, because waiting minutes inside one lookup is worse than reporting it.
  A 401 is not retried: an expired credential will not fix itself.
  `SlateError.rateLimited` is distinct from `.http` so "slow down" can be told
  from "this will never work".
- **`metadata(for: [Lookup])`.** A whole library, in the order asked, with
  bounded concurrency. Three hundred titles started at once is a thousand
  requests in flight, which the providers answer with 429s whatever the rate
  limiter would have preferred.
- **A metadata language.** `TMDBProvider(accessToken:language:)` — titles and
  overviews in `fr-FR` or `ja-JP` where the community supplied them. Artwork is
  deliberately unaffected: every language is fetched and
  `ArtworkSet.best(_:preferring:)` chooses.

### Fixed

- **Film artwork returned nothing when the film arrived by IMDb id.** It required
  a TMDB id outright, while the television path had been looking one up all
  along. Found by testing films for the first time.
- **A film's search names contained the same name twice** whenever its title and
  original title matched — which is every film in its own language. The
  aggregator deduplicated, so this was invisible until a provider was tested on
  its own; `NyaaResolver` stops at the first name that finds anything, and would
  have asked the same question twice. Deduplication now happens where the names
  are made.

### Testing

**Every TMDB request path can now be tested without a credential.** `StubURLProtocol`
answers from canned responses, so search, find, details, episode groups and
artwork are exercised in CI rather than by hand in a terminal. Films had never
been run at all — both bugs above came from the first test that tried one. There
are also tests asserting the token never appears in a URL, that an ordering is
fetched once and remembered, and that a 429 is retried while a 401 is not.

## [0.2.0] — 2026-09-04

Artwork, on the same principle as the rest: one URL is not an answer when a show
has forty posters in a dozen languages and the right one depends on who is
looking.

### Added

- **`ArtworkSet` and `Artwork`.** Every poster, backdrop and logo every provider
  holds, each carrying its language, size, rating and provider. Unsorted, because
  a consumer offering a picker wants the list — `best(_:preferring:)` applies the
  rules when a consumer wants one image.
- **Choosing rules that differ by kind**, which is the domain knowledge worth
  having. Posters and logos follow the viewer's language, and a *textless* image
  beats one in a language nobody asked for — a title treatment in a script the
  viewer cannot read is worse than none. Backdrops invert it: textless wins
  outright, because that is the one that can sit behind a title without two sets
  of words fighting each other. Within a tier, rating then size.
- **`Artwork.sized(atLeast:)`.** A grid of full-size posters is several megabytes
  an item, which on a television is the difference between a list that scrolls and
  one that does not. Providers serving a single size return it unchanged.
- **Season posters** via `artwork(for:kind:season:)`, and `Episode.stillURL`.
- **Logos, without a Fanart.tv key.** TMDB serves them in every language on the
  credential we already have — the same shape as `TVDB Order` arriving without a
  TheTVDB key.

### Caught by running it

Season artwork takes the **provider's own** season number, and the parameter is
named `nativeSeason` to say so. Bleach's arc season 2 lives inside TMDB's season
1; asking TMDB for "season 2" returns Thousand-Year Blood War's 58 posters — a
real picture of the wrong thing, with nothing in the result to indicate it.
`SeasonStructure.nativeSeason(ofSeason:)` does the translation.

### Notes

TMDB reports `""` as the language of an image with no text on it. Slate reads
that as textless rather than as a language called empty string, which is the
difference between finding the best backdrop and never finding one.

Images are fetched unfiltered rather than asking TMDB for one language: filtering
server-side means a second request whenever that language turns out to have
nothing, and for a picker it is the wrong shape entirely.

## [0.1.2] — 2026-09-04

Everything here came out of running real shows against the live API rather than
reasoning about them. Six failures, five of them fixed; the sixth turned out not
to be a failure.

### Fixed

- **A legal drama was filed as anime.** Searching "Suits" matched *Is This a
  Zombie? Of the Dead: Yes, This Suits Me Just Fine* — bare substring
  containment lets a five-letter query match a word buried in a forty-four-letter
  title. Containment still has to be allowed, since "Frieren" is how people ask
  for *Sousou no Frieren*, so the shorter title must now be a substantial part of
  the longer one. Frieren is 47% of its full title and passes; Suits is 11% of
  that zombie title and does not.
- **"Dragon Ball" was resolving to Dragon Ball Z.** TMDB's relevance answers a
  franchise query with its most popular member, and 12971 is *Z* — 301 episodes,
  whose Saiyan saga was the "biggest season" that made the show look correctly
  divided. Requiring an exact title match lands on 12609, the 1986 series, 153
  episodes, which is then correctly split into Toei's six official divisions.
- **"Hunter x Hunter" was resolving to the 1999 adaptation.** 62 episodes and one
  season instead of 148 and three — and every absolute number mapped against the
  wrong run. Among results carrying the asked-for title exactly, which is what a
  remake looks like, the popular one now wins. Where nothing matches the title
  exactly, provider relevance stands: popularity would then be answering a
  question nobody asked.
- **A disambiguating year is no longer part of the name.** AniList files the
  second adaptation as "Hunter x Hunter (2011)", so nothing a person types ever
  matched it. Only parenthesised — a bare trailing year can be the title itself,
  as in *Blade Runner 2049*.
- **`×` now reads as the `x` everyone types.** It is punctuation to `isLetter`,
  so it vanished in normalisation and `HUNTER×HUNTER` never matched
  "Hunter x Hunter". Fixes `SPY×FAMILY` the same way.
- **Jujutsu Kaisen is three seasons, not one of 59.** It slipped under the
  60-episode bar by a single episode. A show filed as a *single* long season is a
  much stronger signal than one long season among many, so that case is read at
  50 — anime seasons are twelve or thirteen, occasionally twenty-six.
- **Shows whose real seasons are in a production ordering are corrected.**
  Jujutsu Kaisen carries no `TVDB Order` and no air-date ordering, so the
  preference chain ran out and returned nothing. `production` and `tv` orderings
  are now a third and last tier — they mean *how this show is divided* rather
  than an alternate cut of it. Still excluded: `absolute` (that is the flat run
  being corrected), `dvd` and `digital` (a release's cut), and `storyArc`. Shows
  carry several and they disagree, so the pick is deterministic: a Latin name
  over the localised duplicate, then fewest groups, then tightest coverage.

### Refused

Two corrections that were not corrections, both caught by running them.

- **Frieren was being split into cours.** Read at two cours, its 38 episodes
  under one number became 16, 12 and 10 — which is not how anyone numbers it;
  releases run straight through to 28. Thirty-eight is not unambiguously more
  than one season, hence the bar at 50.
- **An ordering must actually break up the long run.** Hunter × Hunter's
  `Complete Series` passed every eligibility rule and fixed nothing: it returned
  the 62-episode run untouched as season one and filed the OVAs beside it as
  seasons two to four, so the flattening survived wearing a correction's label.
  The largest new season must be smaller than the one it replaced.

### Not a failure

**The 1999 Hunter × Hunter really is one season of 62 episodes.** Refusing to
correct it was right, and the earlier diagnosis of "TMDB has no usable ordering,
this is the AniDB-shaped gap" was wrong. The OVAs that ordering wanted to add as
seasons — 8, 8 and 14 — are separate works, and AniList lists them as exactly
that.

### Verified against the live API

Corrected: Bleach (366 flat → 17 arcs), Detective Conan (1212 → 31 years),
Jujutsu Kaisen (59 → 24/23/12), Dragon Ball (153 → 6 divisions), One Piece and
Naruto Shippūden via `TVDB Order`. Left alone, correctly: Attack on Titan, Demon
Slayer, SPY×FAMILY, Frieren, Chainsaw Man, Hunter × Hunter (2011, whose own
62/74/12 stands), Suits and Breaking Bad.

## [0.1.1] — 2026-09-04

### Fixed

- **`episodeCount` no longer answers with one season's length.** AniList files a
  *cour* as an entry: its "Attack on Titan" is 25 episodes, because that is
  season one, while TMDB's show is the whole run. With AniList winning every
  field, a series-level question got a season-level answer — a category error, not
  a preference. `episodeCount` is now TMDB-first, while AniList keeps the names,
  the anime flag and everything else a cour-level answer is right for. The cour
  count is still there under `value(from: .aniList)`.

### Added

- **`MetadataAggregator.fieldPriority`.** Per-field provider order, which the
  0.1.0 notes said would arrive when a third provider made the table non-empty.
  It turned out two were enough. Defaults to the one entry above; pass your own
  to override.

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
