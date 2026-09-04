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

    @Test func episodeCountComesFromTheProviderThatCountsTheWholeSeries() {
        // AniList files a cour as an entry: its "Attack on Titan" is 25 episodes
        // because that is season one. TMDB's show is the whole run. Answering a
        // question about one season as though it were the series is the exact
        // confusion this package exists to remove.
        let anilistCour = Snapshot(kind: .series, title: "Shingeki no Kyojin",
                                   episodeCount: 25, isAnime: true)
        let tmdbSeries = Snapshot(ids: Identifiers(imdb: "tt2560140", tmdb: 1429),
                                  kind: .series, title: "Attack on Titan", episodeCount: 89)

        let result = aggregator.assemble([.aniList: anilistCour, .tmdb: tmdbSeries])

        #expect(result.episodeCount.best == 89)
        #expect(result.provenance[.episodeCount] == .tmdb)
        // ...while AniList still wins the things a cour-level answer is right for.
        #expect(result.title.best == "Shingeki no Kyojin")
        #expect(result.isAnime.best == true)
        // And the cour count is not lost, just not the verdict.
        #expect(result.episodeCount.value(from: .aniList) == 25)
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

    @Test func aShortQueryDoesNotMatchAWordBuriedInALongAnimeTitle() {
        // The real failure: searching "Suits" returned *Is This a Zombie? Of the
        // Dead: Yes, This Suits Me Just Fine*, and a legal drama was filed as
        // anime.
        let zombie = "Is This a Zombie? Of the Dead: Yes, This Suits Me Just Fine".normalizedForMatching
        #expect(!zombie.looksLikeTheSameTitleAs("Suits".normalizedForMatching))
    }

    @Test func aShorthandTitleStillMatchesTheFullOne() {
        // ...while the containment that makes this work at all is kept.
        let frieren = "Sousou no Frieren".normalizedForMatching
        #expect(frieren.looksLikeTheSameTitleAs("Frieren".normalizedForMatching))

        let demonSlayer = "Demon Slayer: Kimetsu no Yaiba".normalizedForMatching
        #expect(demonSlayer.looksLikeTheSameTitleAs("Demon Slayer".normalizedForMatching))

        let bleach = "BLEACH".normalizedForMatching
        #expect(bleach.looksLikeTheSameTitleAs("Bleach".normalizedForMatching))
    }

    @Test func aDisambiguatingYearIsNotPartOfTheName() {
        // AniList files the second adaptation as "Hunter x Hunter (2011)", so
        // without this nothing a person types matches it and 1999 wins by
        // default — 62 episodes and one season instead of 148 and three.
        #expect("Hunter x Hunter (2011)".normalizedForMatching
                == "Hunter x Hunter".normalizedForMatching)
        // ...but a year that is the title stays.
        #expect("Blade Runner 2049".normalizedForMatching
                != "Blade Runner".normalizedForMatching)
    }

    @Test func theJapaneseMultiplicationSignIsTheLetterEveryoneTypes() {
        #expect("HUNTER×HUNTER".normalizedForMatching == "Hunter x Hunter".normalizedForMatching)
        #expect("SPY×FAMILY".normalizedForMatching == "Spy x Family".normalizedForMatching)
    }

    @Test func fuzzyTitleMatchingIgnoresPunctuationAndCase() {
        #expect("Fullmetal Alchemist: Brotherhood".normalizedForMatching
                == "fullmetal alchemist brotherhood".normalizedForMatching)
        #expect("Attack on Titan".normalizedForMatching != "Death Note".normalizedForMatching)
    }
}
