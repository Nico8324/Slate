import Foundation

/// Asks every provider at once and keeps all of their answers.
///
/// The aggregator never picks a winner beyond ordering by ``priority``: each
/// field on the result carries every provider that answered it, so a consumer
/// can refresh from one source without silently overwriting a correction that
/// came from another.
public struct MetadataAggregator: Sendable {
    public let providers: [any MetadataProvider]
    /// Highest priority first. Providers missing from this list sort last —
    /// which is where ``Provider/mdbList`` and ``Provider/fribb`` deliberately
    /// sit: the bridge supplies no fields at all, and MDBList's ratings are a
    /// field no other provider answers, so neither has an ordering to lose.
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
        .episodeCount: [.tmdb, .aniList]
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
    /// provider matched is an empty ``TitleMetadata``, not an error.
    public func metadata(for lookup: Lookup) async -> TitleMetadata {
        Log.aggregator.notice(
            "lookup \(Log.describe(lookup), privacy: .public) across \(self.providers.count, privacy: .public) providers"
        )
        var (snapshots, failures) = await ask(providers, lookup)
        var result = assemble(snapshots, failures: failures)
        var asked = lookup

        // Providers that resolve only by id cannot answer a lookup by name —
        // MDBList has no title search, and the anime id bridge has no titles at
        // all — so they stay silent until another provider supplies an id. Each
        // round can unlock the next: TMDB finds the IMDb id, the bridge turns it
        // into a MyAnimeList id, and MDBList can then be asked for MyAnimeList's
        // score. Bounded, and it stops the moment a round learns nothing.
        for round in 0..<Self.resolutionRounds {
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

            let (late, lateFailures) = await ask(silent, asked)
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
        _ providers: [any MetadataProvider], _ lookup: Lookup
    ) async -> (snapshots: [Provider: Snapshot], failures: [Provider: String]) {
        var snapshots: [Provider: Snapshot] = [:]
        var failures: [Provider: String] = [:]

        await withTaskGroup(of: (Provider, Result<Snapshot?, any Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.provider, .success(try await provider.snapshot(for: lookup))) }
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
                    failures[provider] = String(describing: error)
                    Log.aggregator.error(
                        "\(provider.rawValue, privacy: .public) failed — \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        return (snapshots, failures)
    }

    /// How a series is divided.
    ///
    /// **TMDB only, whatever else is in ``providers``.** The correction this
    /// exists for comes out of TMDB's `episode_groups` and has no equivalent
    /// anywhere else, so this asks the `TMDBProvider`s in the list and skips
    /// every other provider — including ones that answer ``metadata(for:)``
    /// perfectly well. Worth saying because `MetadataAggregator(providers:)`
    /// reads as *these are the providers*, and a method consulting a subset of
    /// them by type is invisible until you read the body: adding a provider
    /// here to make seasons work is inert, and nothing fails to tell you so.
    ///
    /// Nor is ``priority`` consulted — there is only ever one answer to prefer.
    /// The first `TMDBProvider` in ``providers`` that returns a structure wins.
    ///
    /// A separate request from ``metadata(for:)`` because it is a separate
    /// question and several requests more expensive. A caller asking *what is
    /// this* should not pay for episode lists it did not ask for.
    public func seasons(for ids: Identifiers) async -> SeasonStructure? {
        let capable = providers.compactMap { $0 as? TMDBProvider }
        guard !capable.isEmpty else {
            // The inert-wiring case: providers were supplied, none of them was a
            // TMDBProvider, and without this the caller sees only nil.
            Log.seasons.error(
                "no TMDBProvider among \(self.providers.count, privacy: .public) providers — seasons are TMDB-only, so this can only return nil"
            )
            return nil
        }
        for provider in capable {
            do {
                if let structure = try await provider.seasons(for: ids) { return structure }
            } catch {
                // Said as a failure, not folded into "no structure": a rejected token, a rate
                // limit and a decode failure all used to read as a show that has no seasons.
                Log.seasons.error(
                    "season structure for \(Log.describe(ids), privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        Log.seasons.notice("no season structure for \(Log.describe(ids), privacy: .public)")
        return nil
    }

    /// Every image every artwork-capable provider holds for one title, merged in
    /// ``priority`` order and left unsorted.
    ///
    /// A provider that cannot supply pictures is skipped by type rather than
    /// asked and found wanting, the same way ``seasons(for:)`` skips one that
    /// cannot supply seasons.
    ///
    /// Never throws: a provider that fails lands in ``ArtworkSet/failures`` and
    /// the rest still answer. Use ``ArtworkSet/best(_:preferring:)`` to choose
    /// one, or hand the whole list to a picker.
    ///
    /// - Parameter nativeSeason: the **provider's own** season number, not one
    ///   from a corrected ``SeasonStructure``. Translate first with
    ///   ``SeasonStructure/nativeSeason(ofSeason:)``: Bleach's arc season 2 lives
    ///   inside TMDB's season 1, and passing 2 straight through returns the
    ///   posters for Thousand-Year Blood War.
    public func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int? = nil) async -> ArtworkSet {
        let capable = providers.compactMap { $0 as? any ArtworkProvider }
        if capable.isEmpty {
            Log.artwork.error(
                "no artwork-capable provider among \(self.providers.count, privacy: .public) — this can only return an empty set"
            )
        }
        var byProvider: [Provider: ArtworkSet] = [:]
        var failures: [Provider: String] = [:]

        await withTaskGroup(of: (Provider, Result<ArtworkSet?, any Error>).self) { group in
            for provider in capable {
                group.addTask {
                    do { return (provider.provider, .success(try await provider.artwork(for: ids, kind: kind, nativeSeason: nativeSeason))) }
                    catch { return (provider.provider, .failure(error)) }
                }
            }
            for await (provider, result) in group {
                switch result {
                case .success(let set): if let set { byProvider[provider] = set }
                case .failure(let error): failures[provider] = String(describing: error)
                }
            }
        }

        var merged = ArtworkSet(failures: failures)
        for provider in byProvider.keys.sorted(by: { rank($0) < rank($1) }) {
            if let set = byProvider[provider] { merged.merge(set) }
        }
        Log.artwork.notice(
            """
            \(Log.describe(ids), privacy: .public)\
            \(nativeSeason.map { " season \($0)" } ?? "", privacy: .public) — \
            \(merged.posters.count, privacy: .public) posters, \
            \(merged.backdrops.count, privacy: .public) backdrops, \
            \(merged.logos.count, privacy: .public) logos
            """
        )
        return merged
    }

    func assemble(_ snapshots: [Provider: Snapshot], failures: [Provider: String] = [:]) -> TitleMetadata {
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
        result.lastEpisodeAirDate = field(.lastEpisodeAirDate, snapshots) { $0.lastEpisodeAirDate }
        result.trailerYouTubeID = field(.trailerYouTubeID, snapshots) { $0.trailerYouTubeID }

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
            rank(lhs.key, in: order) < rank(rhs.key, in: order)
        }
    }

    func rank(_ provider: Provider) -> Int { rank(provider, in: priority) }

    private func rank(_ provider: Provider, in order: [Provider]) -> Int {
        order.firstIndex(of: provider) ?? order.count
    }
}
