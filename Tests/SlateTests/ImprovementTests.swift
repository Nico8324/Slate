import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
    @Suite(.serialized)
    struct Improvements {
        @Test func anExactAnimeIDTakesPrecedenceOverSearchHints() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.stub("graphql.anilist.co", json: """
            {"data":{"Page":{"media":[
              {"id":1,"format":"MOVIE","popularity":100,"title":{"romaji":"Old name"}},
              {"id":2,"format":"TV","startDate":{"year":1999},"title":{"romaji":"Correct title"}}]}}}
            """)
            let result = try await AniListProvider(session: StubURLProtocol.session).snapshot(
                for: Lookup(ids: Identifiers(aniList: 2), query: "Old name", year: 2020, kind: .movie)
            )
            #expect(result?.ids.aniList == 2)
        }

        @Test func inflatedGroupCountsDoNotHideMissingEpisodes() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.stub("/tv/1", json: #"{"seasons":[{"season_number":1,"episode_count":60}]}"#)
            StubURLProtocol.stub("/tv/1/episode_groups", json: """
            {"results":[{"id":"g","name":"TVDB Order","type":1,"group_count":2,"episode_count":60}]}
            """)
            // Sixty rows, but episode 30 occurs twice and episode 60 is absent.
            let groups = [Array(1...30), Array(30...59)].enumerated().map { index, numbers in
                let episodes = numbers.map {
                    "{\"season_number\":1,\"episode_number\":\($0)}"
                }.joined(separator: ",")
                return "{\"order\":\(index),\"name\":\"Arc\",\"episodes\":[\(episodes)]}"
            }.joined(separator: ",")
            StubURLProtocol.stub("/tv/episode_group/g", json: "{\"id\":\"g\",\"name\":\"TVDB Order\",\"groups\":[\(groups)]}")
            let provider = TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
            let result = try await provider.seasons(for: Identifiers(tmdb: 1))
            #expect(result?.ordering == .native)
            #expect(result?.position(ofAbsolute: 60) == EpisodePosition(season: 1, episode: 60))
        }

        @Test func mixedSearchRespectsTheRequestedYear() async throws {
            // A year with no kind is asked of both typed searches, which filter
            // by year on the server — `/search/multi` could not.
            StubURLProtocol.reset()
            StubURLProtocol.respond { request in
                let url = request.url!
                switch url.path {
                case "/3/search/movie":
                    let asked1984 = url.query?.contains("primary_release_year=1984") == true
                    return .init(body: asked1984
                        ? #"{"results":[{"id":2,"title":"Dune","release_date":"1984-12-14","popularity":10}]}"#
                        : #"{"results":[{"id":1,"title":"Dune","release_date":"2021-09-15","popularity":100}]}"#)
                case "/3/search/tv":
                    #expect(url.query?.contains("first_air_date_year=1984") == true)
                    return .init(body: #"{"results":[]}"#)
                default:
                    return .init(body: #"{"id":2,"title":"Dune"}"#)
                }
            }
            let provider = TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
            let result = try await provider.snapshot(for: Lookup(search: "Dune", year: 1984))
            #expect(result?.ids.tmdb == 2)
            #expect(result?.kind == .movie)
            #expect(!StubURLProtocol.requested.contains { $0.path == "/3/search/multi" })
        }

        @Test func emptyTranslationEntriesDoNotBlockTheFallback() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.stub("/tv/1", json: """
            {"id":1,"name":"X","overview":"","translations":{"translations":[
              {"iso_639_1":"fr","iso_3166_1":"FR","data":{"overview":""}},
              {"iso_639_1":"en","iso_3166_1":"GB","data":{"overview":""}},
              {"iso_639_1":"en","iso_3166_1":"US","data":{"overview":"English synopsis"}}]}}
            """)
            let provider = TMDBProvider(accessToken: "t", language: "fr-FR", session: StubURLProtocol.session)
            let result = try await provider.snapshot(for: Lookup(ids: Identifiers(tmdb: 1), kind: .series))
            #expect(result?.overview == "English synopsis")
        }

        @Test func animeSearchRespectsYearAndKind() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.stub("graphql.anilist.co", json: """
            {"data":{"Page":{"media":[
              {"id":1,"format":"TV","popularity":100,"startDate":{"year":2011},"title":{"romaji":"Hunter x Hunter"}},
              {"id":2,"format":"MOVIE","popularity":50,"startDate":{"year":1999},"title":{"romaji":"Hunter x Hunter"}},
              {"id":3,"format":"TV","popularity":10,"startDate":{"year":1999},"title":{"romaji":"Hunter x Hunter"}}]}}}
            """)
            let provider = AniListProvider(session: StubURLProtocol.session)
            let result = try await provider.snapshot(for: Lookup(search: "Hunter x Hunter", year: 1999, kind: .series))
            #expect(result?.ids.aniList == 3)
        }

        @Test func aNameOnlyLookupDoesNotDownloadTheIDBridge() async throws {
            StubURLProtocol.reset()
            StubURLProtocol.stub("anime-list-full.json", json: "[]")
            let bridge = AnimeIDBridge(session: StubURLProtocol.session)
            #expect(try await bridge.snapshot(for: Lookup(search: "Suits")) == nil)
            #expect(StubURLProtocol.requested.isEmpty)
        }
    }
}

struct StablePriorityTests {
    @Test func omittedProvidersHaveAStableOrder() {
        let aggregator = MetadataAggregator(providers: [], priority: [], fieldPriority: [:])
        let result = aggregator.assemble([
            .tmdb: Snapshot(title: "TMDB"), .aniList: Snapshot(title: "AniList"),
            .mdbList: Snapshot(title: "MDBList"), .fribb: Snapshot(title: "Bridge")
        ])
        #expect(result.title.candidates.map(\.provider) == [.aniList, .fribb, .mdbList, .tmdb])
    }
}
