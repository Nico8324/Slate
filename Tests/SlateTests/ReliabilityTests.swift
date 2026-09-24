import Foundation
import Testing
@testable import Slate

private actor LoadGate {
    private var continuation: CheckedContinuation<Data, Never>?
    func load() async -> Data {
        await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: String) {
        continuation?.resume(returning: Data(value.utf8))
        continuation = nil
    }
    var started: Bool { continuation != nil }
}

@Suite(.timeLimit(.minutes(1)))
struct CacheReliabilityTests {
    @Test func concurrentRequestsShareOneLoadAndCancellationIsIndependent() async throws {
        let cache = ResponseCache()
        let gate = LoadGate()
        let first = Task { try await cache.data(for: "key") { await gate.load() } }
        while !(await gate.started) { await Task.yield() }
        let second = Task { try await cache.data(for: "key") { Issue.record("duplicate load"); return Data() } }
        while await cache.waiterCount != 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await cache.waiterCount == 1)
        await gate.release("answer")
        #expect(try await second.value == Data("answer".utf8))
        #expect(await cache.data(for: "key") == Data("answer".utf8))
    }

    @Test func invalidationCannotBeUndoneByAnOldLoad() async throws {
        let cache = ResponseCache()
        let gate = LoadGate()
        let old = Task { try await cache.data(for: "key") { await gate.load() } }
        while !(await gate.started) { await Task.yield() }
        await cache.removeAll()
        await #expect(throws: CancellationError.self) { _ = try await old.value }
        let fresh = try await cache.data(for: "key") { Data("fresh".utf8) }
        await gate.release("stale")
        #expect(fresh == Data("fresh".utf8))
        #expect(await cache.data(for: "key") == fresh)
    }

    @Test func cancellingTheLastWaiterCancelsTheFetch() async throws {
        let cache = ResponseCache()
        let request = Task {
            try await cache.data(for: "key") {
                try await Task.sleep(for: .seconds(30))
                Issue.record("cancelled transport ran to completion")
                return Data()
            }
        }
        while await cache.waiterCount == 0 { await Task.yield() }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(await cache.waiterCount == 0)
        #expect(await cache.data(for: "key") == nil)
    }

    @Test func expiredResponsesAndSeasonStructuresAreNotReused() async throws {
        let cache = ResponseCache(ttl: 0)
        await cache.store(Data(), for: "expired")
        #expect(await cache.data(for: "expired") == nil)
        let provider = TMDBProvider(accessToken: "test", cacheTTL: 0, transport: Stub().transport)
        await provider.rememberSeasons(SeasonStructure(nativeSeasons: [], provider: .tmdb), for: 1)
        #expect(await provider.cachedSeasons(for: 1) == nil)
    }
}

extension TMDBRequestTests {
    struct Reliability {
        let stub = Stub()
        @Test func aLanguageChangeCannotRestoreAnOlderSeasonStructure() async throws {
            let gate = LoadGate()
            stub.respond { request in
                if request.url?.query?.contains("language=en-US") == true {
                    return .init(body: String(decoding: await gate.load(), as: UTF8.self))
                }
                return .init(body: #"{"seasons":[{"season_number":1,"episode_count":12,"name":"Français"}]}"#)
            }
            let provider = TMDBProvider(accessToken: "t", transport: stub.transport)
            let old = Task { try await provider.seasons(for: Identifiers(tmdb: 1)) }
            while !(await gate.started) { await Task.yield() }
            await provider.updateLanguage("fr-FR")
            await #expect(throws: (any Error).self) { _ = try await old.value }
            let fresh = try await provider.seasons(for: Identifiers(tmdb: 1))
            await gate.release(#"{"seasons":[{"season_number":1,"episode_count":12,"name":"English"}]}"#)
            #expect(fresh?.seasons.first?.name == "Français")
            #expect(try await provider.seasons(for: Identifiers(tmdb: 1)) == fresh)
        }

        @Test func animeSearchContinuesToTheNextPage() async throws {
            stub.respond { request in
                let body: Data
                if let data = request.httpBody { body = data }
                else if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        if count <= 0 { break }
                        data.append(contentsOf: bytes.prefix(count))
                    }
                    body = data
                } else { body = Data() }
                let second = String(decoding: body, as: UTF8.self).contains("\"page\":2")
                let year = second ? 1999 : 2011
                return .init(body: "{\"data\":{\"Page\":{\"pageInfo\":{\"hasNextPage\":\(!second)},\"media\":[{\"id\":1,\"format\":\"TV\",\"startDate\":{\"year\":\(year)},\"title\":{\"romaji\":\"Hunter x Hunter\"}}]}}}")
            }
            let result = try await AniListProvider(transport: stub.transport)
                .snapshot(for: Lookup(search: "Hunter x Hunter", year: 1999, kind: .series))
            #expect(result?.ids.aniList == 1)
            #expect(stub.requested.count == 2)
        }

        @Test func aCancelledBridgeDownloadCanBeRetried() async throws {
            let gate = LoadGate()
            stub.respond { _ in .init(body: String(decoding: await gate.load(), as: UTF8.self)) }
            let bridge = AnimeIDBridge(transport: stub.transport)
            let first = Task { try await bridge.snapshot(for: Lookup(imdbID: "tt1")) }
            while !(await gate.started) { await Task.yield() }
            first.cancel()
            await #expect(throws: CancellationError.self) { _ = try await first.value }
            await gate.release("[]")
            stub.respond { _ in .init(body: #"[{"imdb_id":"tt1","anilist_id":1}]"#) }
            #expect(try await bridge.snapshot(for: Lookup(imdbID: "tt1"))?.ids.aniList == 1)
        }

        @Test func credentialsArePartOfTheCacheKey() async throws {
            stub.respond { request in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer valid" {
                    return .init(body: #"{"id":1,"name":"X"}"#)
                }
                return .init(status: 401)
            }
            let provider = TMDBProvider(accessToken: "valid", transport: stub.transport)
            let lookup = Lookup(ids: Identifiers(tmdb: 1), kind: .series)
            _ = try await provider.snapshot(for: lookup)
            await provider.updateAPIKey("rejected")
            await #expect(throws: SlateError.missingCredential(.tmdb)) {
                _ = try await provider.snapshot(for: lookup)
            }
            #expect(stub.requested.count == 2)
        }

        @Test func clearCacheFetchesFreshResponsesAndSeasons() async throws {
            stub.stub("/tv/1", json: #"{"id":1,"name":"X","seasons":[{"season_number":1,"episode_count":12}]}"#)
            let provider = TMDBProvider(accessToken: "t", transport: stub.transport)
            _ = try await provider.seasons(for: Identifiers(tmdb: 1))
            _ = try await provider.seasons(for: Identifiers(tmdb: 1))
            #expect(stub.requested.count == 1)
            await provider.clearCache()
            _ = try await provider.seasons(for: Identifiers(tmdb: 1))
            #expect(stub.requested.count == 2)
        }

        @Test func aYearWithoutAKindCostsTwoSearchesAndFindsAShow() async throws {
            // Was up to 500 pages of `/search/multi`, filtered on the client.
            stub.respond { request in
                switch request.url?.path {
                case "/3/search/movie": .init(body: #"{"results":[]}"#)
                case "/3/search/tv": .init(body: #"{"results":[{"id":7,"name":"Dune","first_air_date":"2000-12-03"}]}"#)
                default: .init(body: #"{"id":7,"name":"Dune"}"#)
                }
            }
            let provider = TMDBProvider(accessToken: "t", transport: stub.transport)
            let snapshot = try await provider.snapshot(for: Lookup(search: "Dune", year: 2000))
            #expect(snapshot?.ids.tmdb == 7)
            #expect(snapshot?.kind == .series)
            #expect(stub.requested.filter { $0.path.hasPrefix("/3/search/") }.count == 2)
        }

        @Test func graphQLErrorsAreFailuresAndAreNotCached() async throws {
            stub.stub("graphql.anilist.co", json: #"{"data":null,"errors":[{"message":"query failed"}]}"#)
            let provider = AniListProvider(transport: stub.transport)
            for _ in 0..<2 {
                await #expect(throws: SlateError.graphQL(.aniList)) {
                    _ = try await provider.snapshot(for: Lookup(search: "X"))
                }
            }
            #expect(stub.requested.count == 2)
        }

        @Test func identicalAnimeQueriesUseTheSameCacheKey() async throws {
            stub.stub("graphql.anilist.co", json: #"{"data":{"Page":{"media":[{"id":1,"title":{"romaji":"X"}}]}}}"#)
            let provider = AniListProvider(transport: stub.transport)
            for _ in 0..<5 { _ = try await provider.snapshot(for: Lookup(search: "X")) }
            #expect(stub.requested.count == 1)
        }
    }
}

struct ValidationTests {
    @Test func aProviderCannotOverrideAnExplicitLookupID() async {
        struct WrongMatch: MetadataProvider {
            let provider = Provider.aniList
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                Snapshot(ids: Identifiers(imdb: "tt2"), title: "Wrong")
            }
        }
        let result = await MetadataAggregator(providers: [WrongMatch()]).metadata(for: Lookup(imdbID: "tt1"))
        #expect(result.title.isEmpty)
        #expect(result.failures[.aniList] != nil)
    }

    @Test func cancellationPreventsStartingProviders() async {
        struct MustNotRun: MetadataProvider {
            let provider = Provider.tmdb
            func snapshot(for lookup: Lookup) async throws -> Snapshot? {
                Issue.record("provider started after cancellation")
                return nil
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MetadataAggregator(providers: [MustNotRun()]).metadata(for: Lookup(search: "X"))
        }
        #expect(await task.value.failures[.tmdb] == "cancelled")
    }

    @Test func conflictingIdentifiersAreNotMerged() {
        let result = MetadataAggregator(providers: []).assemble([
            .aniList: Snapshot(ids: Identifiers(imdb: "tt1"), kind: .series, title: "Correct"),
            .tmdb: Snapshot(ids: Identifiers(imdb: "tt2", tmdb: 2), kind: .series, title: "Other", overview: "Wrong synopsis")
        ])
        #expect(result.ids.imdb == "tt1")
        #expect(result.ids.tmdb == nil)
        #expect(result.overview.isEmpty)
        #expect(result.failures[.tmdb] != nil)
    }

    @Test func invalidPayloadValuesDoNotBecomeMetadata() {
        let snapshot = Snapshot(ids: Identifiers(imdb: "../bad", tmdb: -1), title: "  ",
                                runtimeMinutes: -5, episodeCount: -1, genres: ["", "Drama", "Drama"], rating: .nan)
        #expect(snapshot.ids == Identifiers())
        #expect(snapshot.title == nil)
        #expect(snapshot.runtimeMinutes == nil)
        #expect(snapshot.episodeCount == nil)
        #expect(snapshot.rating == nil)
        #expect(snapshot.genres == ["Drama"])
        #expect("2023-02-29".asReleaseDate == nil)
        #expect("2024-02-29".asReleaseDate != nil)
        #expect("2024-13-01".asReleaseDate == nil)
    }
}
