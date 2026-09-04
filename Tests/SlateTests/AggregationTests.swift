import Foundation
import Testing
@testable import Slate

private struct StubProvider: MetadataProvider {
    let provider: Provider
    let result: Snapshot?
    var failure: (any Error)?

    func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        if let failure { throw failure }
        return result
    }
}

private let tmdbSnapshot = Snapshot(
    ids: Identifiers(imdb: "tt2560140", tmdb: 1429),
    kind: .series,
    title: "Attack on Titan",
    overview: "TMDB's summary",
    rating: 8.6,
    searchNames: ["Attack on Titan", "Shingeki no Kyojin"]
)

private let aniListSnapshot = Snapshot(
    ids: Identifiers(aniList: 16498, myAnimeList: 16498),
    kind: .series,
    title: "Shingeki no Kyojin",
    overview: "AniList's summary",
    rating: 8.4,
    isAnime: true,
    searchNames: ["Shingeki no Kyojin", "Attack on Titan", "進撃の巨人"]
)

struct AggregationTests {
    private let aggregator = MetadataAggregator(providers: [])

    @Test func keepsEveryProvidersAnswerInPriorityOrder() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        #expect(result.overview.candidates.count == 2)
        #expect(result.overview.best == "AniList's summary")
        #expect(result.overview.bestProvider == .aniList)
        #expect(result.overview.value(from: .tmdb) == "TMDB's summary")
        #expect(result.rating.value(from: .tmdb) == 8.6)
    }

    @Test func mergesIdentifiersAcrossProviders() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        #expect(result.ids.imdb == "tt2560140")
        #expect(result.ids.tmdb == 1429)
        #expect(result.ids.aniList == 16498)
    }

    @Test func searchNamesAreRomajiFirstAndDeduplicated() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        #expect(result.searchNames == ["Shingeki no Kyojin", "Attack on Titan", "進撃の巨人"])
    }

    @Test func priorityIsConfigurable() {
        let tmdbFirst = MetadataAggregator(providers: [], priority: [.tmdb, .aniList])
        let result = tmdbFirst.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        #expect(result.overview.best == "TMDB's summary")
        #expect(result.searchNames.first == "Attack on Titan")
    }

    @Test func aFieldNoProviderAnsweredIsEmptyRatherThanGuessed() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot])

        #expect(result.isAnime.isEmpty)
        #expect(result.isAnime.best == nil)
    }

    @Test func provenanceIsAddressablePerFieldWithoutKnowingFieldTypes() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        // The point: a consumer can loop over fields to decide what a hand-edit
        // freezes, instead of writing one branch per field.
        #expect(result.provenance[.overview] == .aniList)
        #expect(result.provenance[.isAnime] == .aniList)
        #expect(result.provenance[.releaseDate] == nil, "no provider answered it")
        #expect(result.providersConsulted(for: .title) == [.aniList, .tmdb])
    }

    @Test func dissentIsReachableButNotTheDefaultRead() {
        let result = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])

        #expect(result.overview.best == "AniList's summary")
        #expect(result.overview.dissent.map(\.provider) == [.tmdb])
        #expect(result.overview.dissent.first?.value == "TMDB's summary")
        #expect(aggregator.assemble([.tmdb: tmdbSnapshot]).overview.dissent.isEmpty)
    }

    @Test func resolveInputNeedsAnIMDbIDAndAKind() {
        #expect(aggregator.assemble([.aniList: aniListSnapshot]).resolveInput == nil)

        let both = aggregator.assemble([.tmdb: tmdbSnapshot, .aniList: aniListSnapshot])
        #expect(both.resolveInput?.imdbID == "tt2560140")
        #expect(both.resolveInput?.kind == .series)
        #expect(both.resolveInput?.searchNames.first == "Shingeki no Kyojin")
    }

    @Test func oneProviderFailingDoesNotLoseTheOthers() async {
        let aggregator = MetadataAggregator(providers: [
            StubProvider(provider: .tmdb, result: tmdbSnapshot),
            StubProvider(provider: .aniList, result: nil, failure: SlateError.http(status: 500, body: "")),
        ])

        let result = await aggregator.metadata(for: Lookup(search: "Attack on Titan"))

        #expect(result.title.best == "Attack on Titan")
        #expect(result.failures[.aniList] != nil)
        #expect(result.failures[.tmdb] == nil)
    }
}

struct ProviderTests {
    @Test func tmdbRefusesToWorkWithoutACredential() async {
        let provider = TMDBProvider(accessToken: "")

        await #expect(throws: SlateError.missingCredential(.tmdb)) {
            try await provider.snapshot(for: Lookup(search: "Dune"))
        }
    }

    @Test func aniListSkipsLookupsWithNoNameToSearchBy() async throws {
        // There is no id bridge from IMDb to AniList, so this cannot be asked.
        let result = try await AniListProvider().snapshot(for: Lookup(imdbID: "tt0111161"))

        #expect(result == nil)
    }

    @Test func synonymsInOtherScriptsAreNotWorthSearchingFor() {
        #expect("Ataque a los Titanes".isMostlyLatin)
        #expect("Ataque dos Titãs".isMostlyLatin)
        #expect(!"進撃の巨人".isMostlyLatin)
        #expect(!"الهجوم على العمالقة".isMostlyLatin)
    }

    @Test func fuzzyTitleMatchingIgnoresPunctuationAndCase() {
        #expect("Fullmetal Alchemist: Brotherhood".normalizedForMatching
                == "fullmetal alchemist brotherhood".normalizedForMatching)
        #expect("Attack on Titan".normalizedForMatching != "Death Note".normalizedForMatching)
    }
}
