import Foundation

/// Asks every provider at once and keeps all of their answers.
///
/// The aggregator never picks a winner beyond ordering by ``priority``: each
/// field on the result carries every provider that answered it, so a consumer
/// can refresh from one source without silently overwriting a correction that
/// came from another.
public struct MetadataAggregator: Sendable {
    public let providers: [any MetadataProvider]
    /// Highest priority first. Providers missing from this list sort last.
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
        var (snapshots, failures) = await ask(providers, lookup)
        var result = assemble(snapshots, failures: failures)
        var asked = lookup

        // Providers that resolve only by id cannot answer a lookup by name —
        // MDBList has no title search, and the anime id bridge has no titles at
        // all — so they stay silent until another provider supplies an id. Each
        // round can unlock the next: TMDB finds the IMDb id, the bridge turns it
        // into a MyAnimeList id, and MDBList can then be asked for MyAnimeList's
        // score. Bounded, and it stops the moment a round learns nothing.
        for _ in 0..<Self.resolutionRounds {
            let silent = providers.filter {
                snapshots[$0.provider] == nil && failures[$0.provider] == nil
            }
            var next = asked
            next.ids.fill(from: result.ids)
            guard !silent.isEmpty, next.ids != asked.ids else { break }
            asked = next

            let (late, lateFailures) = await ask(silent, asked)
            guard !late.isEmpty || !lateFailures.isEmpty else { break }
            snapshots.merge(late) { first, _ in first }
            failures.merge(lateFailures) { first, _ in first }
            result = assemble(snapshots, failures: failures)
        }
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
                case .success(let snapshot): snapshots[provider] = snapshot
                case .failure(let error): failures[provider] = String(describing: error)
                }
            }
        }
        return (snapshots, failures)
    }

    /// How a series is divided, from the first season-capable provider that can
    /// say — in ``priority`` order.
    ///
    /// A separate request from ``metadata(for:)`` because it is a separate
    /// question and several requests more expensive. A caller asking *what is
    /// this* should not pay for episode lists it did not ask for.
    public func seasons(for ids: Identifiers) async -> SeasonStructure? {
        for provider in providers.compactMap({ $0 as? TMDBProvider }) {
            if let structure = try? await provider.seasons(for: ids) { return structure }
        }
        return nil
    }

    ///
    /// Results come back in the order asked. Concurrency is bounded because a
    /// scan is the case that breaks things: three hundred titles started at once
    /// is a thousand requests in flight, and the providers answer that with 429s
    /// whatever the rate limiter would have preferred.
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
