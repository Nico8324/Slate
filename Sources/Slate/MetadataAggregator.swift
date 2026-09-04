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

    public init(providers: [any MetadataProvider], priority: [Provider] = [.aniList, .tmdb]) {
        self.providers = providers
        self.priority = priority
    }

    /// Asks every provider concurrently and assembles one answer.
    ///
    /// Never throws: a provider that fails is recorded in
    /// ``TitleMetadata/failures`` and the rest still answer. A result where no
    /// provider matched is an empty ``TitleMetadata``, not an error.
    public func metadata(for lookup: Lookup) async -> TitleMetadata {
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

        return assemble(snapshots, failures: failures)
    }

    func assemble(_ snapshots: [Provider: Snapshot], failures: [Provider: String] = [:]) -> TitleMetadata {
        let ordered = sorted(snapshots)
        var result = TitleMetadata(failures: failures)

        for (provider, snapshot) in ordered {
            result.ids.fill(from: snapshot.ids)
            result.kind.append(snapshot.kind, from: provider)
            result.title.append(snapshot.title, from: provider)
            result.originalTitle.append(snapshot.originalTitle, from: provider)
            result.overview.append(snapshot.overview, from: provider)
            result.releaseDate.append(snapshot.releaseDate, from: provider)
            result.runtimeMinutes.append(snapshot.runtimeMinutes, from: provider)
            result.episodeCount.append(snapshot.episodeCount, from: provider)
            result.genres.append(snapshot.genres, from: provider)
            result.rating.append(snapshot.rating, from: provider)
            result.posterURL.append(snapshot.posterURL, from: provider)
            result.backdropURL.append(snapshot.backdropURL, from: provider)
            result.isAnime.append(snapshot.isAnime, from: provider)
        }

        result.searchNames = deduplicated(ordered.flatMap(\.1.searchNames))
        return result
    }

    private func sorted(_ snapshots: [Provider: Snapshot]) -> [(Provider, Snapshot)] {
        snapshots.sorted { lhs, rhs in
            rank(lhs.key) < rank(rhs.key)
        }
    }

    private func rank(_ provider: Provider) -> Int {
        priority.firstIndex(of: provider) ?? priority.count
    }

    /// Case- and whitespace-insensitive, first occurrence wins.
    private func deduplicated(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}
