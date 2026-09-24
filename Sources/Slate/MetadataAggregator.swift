import Foundation

/// Asks every provider concurrently and attributes each accepted answer.
///
/// Conflicting shared IDs or media kinds exclude lower-priority snapshots;
/// answers contradicting an explicit lookup ID are rejected regardless of priority.
/// Rejections and request errors appear in ``TitleMetadata/failures``. Each field
/// retains all accepted values, ordered by its configured provider priority.
public struct MetadataAggregator: Sendable {
    public let providers: [any MetadataProvider]
    /// Highest priority first. Unlisted providers sort last, alphabetically by
    /// identifier. This order also decides which conflicting snapshot is retained.
    /// Field-specific priorities apply only after a snapshot has been accepted.
    public let priority: [Provider]

    /// Priority for fields where the general order is the wrong answer.
    ///
    /// One entry today, and it is not a preference — it is a category error being
    /// corrected. AniList files a *cour* as an entry: "Attack on Titan" there is
    /// 25 episodes, because that is season one, while TMDB's show is the whole
    /// run. Letting AniList win `episodeCount` would answer a question about one
    /// season as though it were the series, which is exactly the confusion this
    /// package exists to remove. AniList still wins the names and the anime flag,
    /// where a cour-level answer is the right one.
    public let fieldPriority: [FieldKey: [Provider]]

    public static let defaultFieldPriority: [FieldKey: [Provider]] = [
        .episodeCount: [.tmdb, .aniList],
        // MDBList first, and this is the same kind of correction as
        // `episodeCount`. TMDB and AniList each answer `ratings` with their own
        // single score; MDBList answers with IMDb, Metacritic, the tomatometer,
        // Letterboxd and MyAnimeList at once. Under the general order the
        // one-entry list would win a field whose whole point is breadth.
        .ratings: [.mdbList, .tmdb, .aniList]
    ]

    public init(
        providers: [any MetadataProvider],
        priority: [Provider] = [.aniList, .tmdb],
        fieldPriority: [FieldKey: [Provider]] = MetadataAggregator.defaultFieldPriority
    ) {
        self.providers = providers
        self.priority = priority
        self.fieldPriority = fieldPriority
    }

    /// Asks every provider concurrently and assembles one answer.
    ///
    /// Never throws: a provider that fails is recorded in
    /// ``TitleMetadata/failures`` and the rest still answer. A result where no
    /// provider matched is an empty ``TitleMetadata``, not an error. Cancellation
    /// stops enrichment and can return partial results with failure descriptions.
    public func metadata(for lookup: Lookup) async -> TitleMetadata {
        Log.aggregator.notice(
            "lookup \(Log.describe(lookup), privacy: .public) across \(self.providers.count, privacy: .public) providers"
        )
        var (snapshots, failures) = await ask(providers, lookup, explicit: lookup.ids)
        var result = assemble(snapshots, failures: failures)
        var asked = lookup

        // Providers that resolve only by id cannot answer a lookup by name —
        // MDBList has no title search, and the anime id bridge has no titles at
        // all — so they stay silent until another provider supplies an id. Each
        // round can unlock the next: TMDB finds the IMDb id, the bridge turns it
        // into a MyAnimeList id, and MDBList can then be asked for MyAnimeList's
        // score. Bounded, and it stops the moment a round learns nothing.
        for round in 0..<Self.resolutionRounds {
            guard !Task.isCancelled else { break }
            let silent = providers.filter {
                snapshots[$0.provider] == nil && failures[$0.provider] == nil
            }
            var next = asked
            next.ids.fill(from: result.ids)
            // The kind too: a TMDB id names a film or a show depending on which it is, and a
            // provider asked by one with no kind (MDBList's `/tmdb/any/`) could answer about
            // the other.
            next.kind = next.kind ?? result.kind.best
            guard !silent.isEmpty, next.ids != asked.ids || next.kind != asked.kind else { break }
            asked = next

            // Checked against what the caller asked for, not against ids other providers
            // supplied along the way: those can disagree with each other, and priority
            // settles that in `assemble` — a learned id is not an explicit one.
            let (late, lateFailures) = await ask(silent, asked, explicit: lookup.ids)
            guard !late.isEmpty || !lateFailures.isEmpty else { break }
            snapshots.merge(late) { first, _ in first }
            failures.merge(lateFailures) { first, _ in first }
            result = assemble(snapshots, failures: failures)
            Log.aggregator.debug(
                "round \(round + 2, privacy: .public) asked \(silent.map(\.provider.rawValue).sorted().joined(separator: ","), privacy: .public) with the ids learned so far"
            )
        }
        // The one line that answers "why is this field missing" without a
        // debugger: who answered, who was asked and failed, and who was in the
        // list but said nothing at all.
        let silentThroughout = providers.map(\.provider)
            .filter { snapshots[$0] == nil && failures[$0] == nil }
        Log.aggregator.notice(
            """
            \(Log.describe(lookup), privacy: .public) → \
            answered: \(snapshots.keys.map(\.rawValue).sorted().joined(separator: ",").nilIfEmpty ?? "none", privacy: .public); \
            failed: \(failures.keys.map(\.rawValue).sorted().joined(separator: ",").nilIfEmpty ?? "none", privacy: .public); \
            no match: \(silentThroughout.map(\.rawValue).sorted().joined(separator: ",").nilIfEmpty ?? "none", privacy: .public)
            """
        )
        return result
    }

    /// Two extra rounds: enough for id → bridge → id-only provider, and few
    /// enough that a misbehaving provider cannot turn one lookup into a loop.
    static let resolutionRounds = 2

    private func ask(
        _ providers: [any MetadataProvider], _ lookup: Lookup, explicit: Identifiers
    ) async -> (snapshots: [Provider: Snapshot], failures: [Provider: String]) {
        var snapshots: [Provider: Snapshot] = [:]
        var failures: [Provider: String] = [:]

        await withTaskGroup(of: (Provider, Result<Snapshot?, any Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        try lookup.validate()
                        let snapshot = try await provider.snapshot(for: lookup)
                        if let snapshot, explicit.conflicts(with: snapshot.ids) {
                            throw SlateError.conflictingMatch(provider.provider)
                        }
                        return (provider.provider, .success(snapshot))
                    }
                    catch { return (provider.provider, .failure(error)) }
                }
            }
            for await (provider, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[provider] = snapshot
                    if snapshot == nil {
                        // Not a failure. AniList returns this for every western
                        // title, and it is the state that looks identical to a
                        // provider that was never asked.
                        Log.aggregator.debug("\(provider.rawValue, privacy: .public) — no match")
                    }
                case .failure(let error):
                    failures[provider] = Log.describeFailure(error)
                    Log.aggregator.error(
                        "\(provider.rawValue, privacy: .public) failed — \(Log.describe(error), privacy: .public)"
                    )
                }
            }
        }
        return (snapshots, failures)
    }

    func assemble(_ snapshots: [Provider: Snapshot], failures: [Provider: String] = [:]) -> TitleMetadata {
        var failures = failures
        var accepted: [Provider: Snapshot] = [:]
        var ids = Identifiers()
        var kind: Kind?
        // Exact and id matches are accepted before loose ones, so a fuzzy name
        // match cannot evict a precise answer by outranking it: "Love" (the
        // film) matched *Love Live!* on AniList by containment, and AniList's
        // priority used to throw TMDB's film and its IMDb id away.
        let byConfidence = sorted(snapshots, by: priority).sorted { !$0.1.matchedLoosely && $1.1.matchedLoosely }
        for (provider, snapshot) in byConfidence {
            if ids.conflicts(with: snapshot.ids)
                || (kind != nil && snapshot.kind != nil && kind != snapshot.kind) {
                failures[provider] = "Conflicting provider match: identifiers or media kind disagree"
                continue
            }
            accepted[provider] = snapshot
            ids.fill(from: snapshot.ids)
            kind = kind ?? snapshot.kind
        }
        let snapshots = accepted
        var result = TitleMetadata(failures: failures)

        for (_, snapshot) in sorted(snapshots, by: priority) {
            result.ids.fill(from: snapshot.ids)
        }

        result.kind = field(.kind, snapshots) { $0.kind }
        result.title = field(.title, snapshots) { $0.title }
        result.originalTitle = field(.originalTitle, snapshots) { $0.originalTitle }
        result.overview = field(.overview, snapshots) { $0.overview }
        result.releaseDate = field(.releaseDate, snapshots) { $0.releaseDate }
        result.runtimeMinutes = field(.runtimeMinutes, snapshots) { $0.runtimeMinutes }
        result.episodeCount = field(.episodeCount, snapshots) { $0.episodeCount }
        result.genres = field(.genres, snapshots) { $0.genres }
        result.rating = field(.rating, snapshots) { $0.rating }
        result.posterURL = field(.posterURL, snapshots) { $0.posterURL }
        result.backdropURL = field(.backdropURL, snapshots) { $0.backdropURL }
        result.isAnime = field(.isAnime, snapshots) { $0.isAnime }
        result.contentRating = field(.contentRating, snapshots) { $0.contentRating }
        result.cast = field(.cast, snapshots) { $0.cast }
        result.crew = field(.crew, snapshots) { $0.crew }
        result.trailers = field(.trailers, snapshots) { $0.trailers }
        result.recommendations = field(.recommendations, snapshots) { $0.recommendations }
        result.ratings = field(.ratings, snapshots) { $0.ratings }
        result.watchOptions = field(.watchOptions, snapshots) { $0.watchOptions }
        result.keywords = field(.keywords, snapshots) { $0.keywords }
        result.studios = field(.studios, snapshots) { $0.studios }
        result.originalLanguage = field(.originalLanguage, snapshots) { $0.originalLanguage }
        result.originCountries = field(.originCountries, snapshots) { $0.originCountries }
        result.franchise = field(.franchise, snapshots) { $0.franchise }
        result.status = field(.status, snapshots) { $0.status }
        result.relations = field(.relations, snapshots) { $0.relations }
        result.nextEpisodeAirDate = field(.nextEpisodeAirDate, snapshots) { $0.nextEpisodeAirDate }
        result.nextEpisode = field(.nextEpisode, snapshots) { $0.nextEpisode }
        result.lastEpisodeAirDate = field(.lastEpisodeAirDate, snapshots) { $0.lastEpisodeAirDate }
        result.homeReleaseDate = field(.homeReleaseDate, snapshots) { $0.homeReleaseDate }
        result.trailerYouTubeID = field(.trailerYouTubeID, snapshots) { $0.trailerYouTubeID }
        result.artwork = field(.artwork, snapshots) { $0.artwork }

        result.searchNames = sorted(snapshots, by: priority).flatMap(\.1.searchNames).deduplicatedNames
        return result
    }

    /// One field, ordered by that field's own priority where it has one.
    private func field<Value>(
        _ key: FieldKey,
        _ snapshots: [Provider: Snapshot],
        _ value: (Snapshot) -> Value?
    ) -> Field<Value> {
        var result = Field<Value>()
        for (provider, snapshot) in sorted(snapshots, by: fieldPriority[key] ?? priority) {
            result.append(value(snapshot), from: provider)
        }
        return result
    }

    private func sorted(_ snapshots: [Provider: Snapshot], by order: [Provider]) -> [(Provider, Snapshot)] {
        snapshots.sorted { lhs, rhs in
            (rank(lhs.key, in: order), lhs.key.rawValue) < (rank(rhs.key, in: order), rhs.key.rawValue)
        }
    }

    private func rank(_ provider: Provider, in order: [Provider]) -> Int {
        order.firstIndex(of: provider) ?? order.count
    }
}
