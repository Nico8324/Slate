import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  struct AniListFields {
    let stub = Stub()

    /// Attack on Titan's real shape, trimmed to what is asserted.
    private func stubAttackOnTitan() {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[{
          "id":16498,"idMal":16498,"format":"TV","episodes":25,"popularity":837840,
          "status":"FINISHED","countryOfOrigin":"JP","averageScore":84,
          "stats":{"scoreDistribution":[{"amount":100},{"amount":900}]},
          "title":{"romaji":"Shingeki no Kyojin","english":"Attack on Titan"},
          "studios":{"edges":[
            {"isMain":true,"node":{"name":"WIT STUDIO"}},
            {"isMain":false,"node":{"name":"Pony Canyon"}},
            {"isMain":false,"node":{"name":"Dentsu"}}]},
          "tags":[{"name":"Kaiju","rank":93},{"name":"Tragedy","rank":88},
                  {"name":"Philosophy","rank":41}],
          "relations":{"edges":[
            {"relationType":"ADAPTATION","node":{"id":53390,"format":"MANGA","title":{"romaji":"Shingeki no Kyojin"}}},
            {"relationType":"SEQUEL","node":{"id":20958,"idMal":25777,"format":"TV","title":{"romaji":"Shingeki no Kyojin Season 2"}}},
            {"relationType":"SIDE_STORY","node":{"id":18397,"format":"OVA","title":{"romaji":"Shingeki no Kyojin OVA"}}}]},
          "characters":{"edges":[
            {"role":"MAIN","node":{"name":{"full":"Eren Yeager"}},
             "voiceActors":[{"id":95672,"name":{"full":"Yuuki Kaji"},"image":{"large":"https://s4.anilist.co/e.png"}}]},
            {"role":"SUPPORTING","node":{"name":{"full":"Hange Zoe"}},"voiceActors":[]}]}
        }]}}}
        """)
    }

    private func snapshot() async throws -> Snapshot {
        stubAttackOnTitan()
        return try #require(await AniListProvider(transport: stub.transport)
            .snapshot(for: Lookup(search: "Attack on Titan")))
    }

    @Test func aSequelIsALinkBecauseItIsASeparateWork() async throws {
        // Season 2 has its own id and its own episode numbering from one. The
        // sequel edge is the only thing tying it to season 1.
        let relations = try #require(await snapshot().relations)
        let sequel = try #require(relations.first { $0.kind == .sequel })

        #expect(sequel.title == "Shingeki no Kyojin Season 2")
        #expect(sequel.ids.aniList == 20958)
        #expect(sequel.ids.myAnimeList == 25777)
        #expect(relations.map(\.kind).contains(.sideStory))
    }

    @Test func aRelatedMangaIsNotSomethingALibraryCanPlay() async throws {
        let relations = try #require(await snapshot().relations)

        #expect(relations.contains { $0.kind == .adaptation && !$0.isWatchable })
        #expect(relations.filter(\.isWatchable).count == 2)
    }

    @Test func theStudioIsTheAnimatorNotTheCommittee() async throws {
        // AniList lists producers, licensors and broadcasters beside the studio;
        // naming all of them answers a question nobody asked.
        #expect(try await snapshot().studios == ["WIT STUDIO"])
    }

    @Test func aTagTwoPeopleAgreedOnIsNotAKeyword() async throws {
        #expect(try await snapshot().keywords == ["Kaiju", "Tragedy"], "rank 41 is noise")
    }

    @Test func anAnimeCastIsItsVoiceActors() async throws {
        let cast = try #require(await snapshot().cast)

        #expect(cast.count == 1, "a character with no listed actor is not a credit")
        #expect(cast.first?.name == "Yuuki Kaji")
        #expect(cast.first?.character == "Eren Yeager")
        #expect(cast.first?.profileURL != nil)
    }

    @Test func statusIsOneVocabularyAcrossProviders() async throws {
        // AniList says FINISHED, TMDB says Ended. A consumer comparing the two
        // should not have to know either word.
        #expect(try await snapshot().status == .ended)
        #expect(ReleaseStatus(providerValue: "Returning Series") == .airing)
        #expect(ReleaseStatus(providerValue: "RELEASING") == .airing)
        #expect(ReleaseStatus(providerValue: "NOT_YET_RELEASED") == .upcoming)
        #expect(ReleaseStatus(providerValue: "Released") == .released)
        #expect(ReleaseStatus(providerValue: "nonsense") == nil, "an unknown word is not a status")
    }

    @Test func theCountryIsAniListsAnswerAndNotAnAssumption() async throws {
        let snapshot = try await snapshot()
        #expect(snapshot.originalLanguage == "ja")
        #expect(snapshot.originCountries == ["JP"])
    }

    /// `type: ANIME` is not `made in Japan`: AniList catalogues Chinese donghua
    /// and Korean aeni under it, and this used to answer `ja`/`JP` for both.
    @Test func donghuaIsNotJapanese() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[{
          "id":1,"format":"TV","countryOfOrigin":"CN",
          "title":{"romaji":"Mo Dao Zu Shi"}}]}}}
        """)

        let snapshot = try #require(await AniListProvider(transport: stub.transport)
            .snapshot(for: Lookup(search: "Mo Dao Zu Shi")))

        #expect(snapshot.originalLanguage == "zh")
        #expect(snapshot.originCountries == ["CN"])
    }

    /// Silence, not a guess, when AniList does not say.
    @Test func noCountryMeansNoClaim() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[{"id":2,"format":"TV","title":{"romaji":"Unknown"}}]}}}
        """)

        let snapshot = try #require(await AniListProvider(transport: stub.transport)
            .snapshot(for: Lookup(search: "Unknown")))

        #expect(snapshot.originalLanguage == nil)
        #expect(snapshot.originCountries == nil)
    }

    /// The vote count is the number who scored it, not the number who listed it.
    @Test func theScoreCarriesHowManyPeopleGaveIt() async throws {
        let ratings = try #require(try await snapshot().ratings)
        #expect(ratings.map(\.source) == ["anilist"])
        #expect(ratings.first?.value == 8.4)
        #expect(ratings.first?.votes == 1000, "the distribution summed, not popularity's 837840")
    }
  }
}

struct AniListSearchTests {
    let stub = Stub()

    @Test func aniListChartsAskForTheKindAndSeasonAndReadEnglishFirst() async throws {
        stub.respond { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while case let count = stream.read(&bytes, maxLength: bytes.count), count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = String(decoding: data, as: UTF8.self)
            #expect(body.contains(#""format":["TV","TV_SHORT","ONA"]"#))
            #expect(body.contains(#""season":"FALL""#) && body.contains(#""seasonYear":2026"#))
            return .init(body: """
            {"data":{"Page":{"media":[
              {"id":16498,"idMal":16498,"title":{"romaji":"Shingeki no Kyojin","english":"Attack on Titan"},
               "startDate":{"year":2013},"coverImage":{"extraLarge":"https://img.anili.st/c.jpg"}},
              {"id":2,"title":{"romaji":"Only Romaji"}},
              {"id":0,"title":{"romaji":"No id"}}]}}}
            """)
        }
        let october = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let titles = try await AniListProvider(transport: stub.transport)
            .titles(in: .thisSeason, kind: .series, now: october)
        #expect(titles.map(\.title) == ["Attack on Titan", "Only Romaji"])
        #expect(titles.first?.ids == Identifiers(aniList: 16498, myAnimeList: 16498))
        #expect(titles.first?.kind == .series)
        #expect(titles.first?.posterURL != nil)
    }

    @Test func aGraphQLErrorIsNotAnEmptyChart() async {
        stub.stub("graphql.anilist.co", json: #"{"data":null,"errors":[{"message":"x"}]}"#)
        await #expect(throws: SlateError.graphQL(.aniList)) {
            try await AniListProvider(transport: stub.transport).titles(in: .trending, kind: .movie)
        }
    }

    @Test func broadcastSeasonsFollowTheJapaneseCalendar() {
        func date(_ month: Int) -> Date {
            Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: 2026, month: month, day: 15))!
        }
        #expect(AniListProvider.season(of: date(1)).season == "WINTER")
        #expect(AniListProvider.season(of: date(5)).season == "SPRING")
        #expect(AniListProvider.season(of: date(8)).season == "SUMMER")
        #expect(AniListProvider.season(of: date(11)).season == "FALL")
    }

    @Test func anExactAnimeIDTakesPrecedenceOverSearchHints() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[
          {"id":1,"format":"MOVIE","popularity":100,"title":{"romaji":"Old name"}},
          {"id":2,"format":"TV","startDate":{"year":1999},"title":{"romaji":"Correct title"}}]}}}
        """)
        let result = try await AniListProvider(transport: stub.transport).snapshot(
            for: Lookup(ids: Identifiers(aniList: 2), query: "Old name", year: 2020, kind: .movie)
        )
        #expect(result?.ids.aniList == 2)
    }

    /// Announcements are often only "October 2027", or "2027": the first day of what's
    /// known, and how much is.
    @Test func anAnnouncedAnimeKeepsHowMuchOfItsDateIsKnown() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[
          {"id":1,"format":"TV","startDate":{"year":2026,"month":10,"day":2},"title":{"romaji":"Day"}},
          {"id":2,"format":"TV","startDate":{"year":2027,"month":10},"title":{"romaji":"Month"}},
          {"id":3,"format":"TV","startDate":{"year":2027},"title":{"romaji":"Year"}},
          {"id":4,"format":"TV","startDate":{},"title":{"romaji":"Unknown"}}]}}}
        """)
        let titles = try await AniListProvider(transport: stub.transport).titles(in: .upcoming, kind: .series)

        #expect(titles.map(\.releasePrecision) == [.day, .month, .year, nil])
        #expect(titles[1].releaseDate == (try Date("2027-10-01T00:00:00Z", strategy: .iso8601)))
        #expect(titles[3].releaseDate == nil)
    }

    @Test func animeSearchRespectsYearAndKind() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"media":[
          {"id":1,"format":"TV","popularity":100,"startDate":{"year":2011},"title":{"romaji":"Hunter x Hunter"}},
          {"id":2,"format":"MOVIE","popularity":50,"startDate":{"year":1999},"title":{"romaji":"Hunter x Hunter"}},
          {"id":3,"format":"TV","popularity":10,"startDate":{"year":1999},"title":{"romaji":"Hunter x Hunter"}}]}}}
        """)
        let provider = AniListProvider(transport: stub.transport)
        let result = try await provider.snapshot(for: Lookup(search: "Hunter x Hunter", year: 1999, kind: .series))
        #expect(result?.ids.aniList == 3)
    }

    @Test func aFilteredSearchStopsAfterThreePages() async throws {
        stub.stub("graphql.anilist.co", json: """
        {"data":{"Page":{"pageInfo":{"hasNextPage":true},"media":[
          {"id":1,"format":"TV","startDate":{"year":2011},"title":{"romaji":"Hunter x Hunter"}}]}}}
        """)
        let result = try await AniListProvider(transport: stub.transport)
            .snapshot(for: Lookup(search: "Hunter x Hunter", year: 1999, kind: .series))
        #expect(result == nil)
        #expect(stub.requested.count == 3)
    }
}
