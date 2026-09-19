import Foundation
import Testing
@testable import Slate

extension TMDBRequestTests {
  @Suite(.serialized)
  struct BridgeAndCache {

    /// Real rows from the published list, trimmed. Entries 2 and 3 are the
    /// case that matters: two different works sharing one IMDb id.
    private let rows = """
    [{"anidb_id":1,"anilist_id":290,"mal_id":290,"imdb_id":["tt0286390"],
      "themoviedb_id":{"tv":26209},"thetvdb_id":72025,"season":{"tvdb":1,"tmdb":1}},
     {"anidb_id":2,"anilist_id":300,"mal_id":300,"imdb_id":["tt0102847"],
      "themoviedb_id":{"tv":62913},"season":{"tvdb":1,"tmdb":1}},
     {"anidb_id":3,"anilist_id":1225,"mal_id":1225,"imdb_id":["tt0102847"],
      "themoviedb_id":{"tv":62913},"season":{"tvdb":2,"tmdb":2}},
     {"anidb_id":9,"anilist_id":16498,"mal_id":16498,"imdb_id":"tt2560140",
      "themoviedb_id":1429}]
    """

    private func bridge() throws -> AnimeIDBridge {
        let entries = try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8))
        let bridge = AnimeIDBridge()
        Task { await bridge.index(entries) }
        return bridge
    }

    @Test func aColdBridgeAskedBySeveralAtOnceDownloadsOnceAndStaysCorrect() async throws {
        // A library scan is the only workload that asks about several anime at
        // once, and it is also the only one that finds a cold bridge. Before the
        // stored task, each caller passed `guard !loaded` during the other's
        // download: five fetches of 7.5 MB, and — because `index` appends —
        // every entry filed five times, so every id resolved to five candidates
        // and therefore to nil. The bridge went quiet for everything.
        StubURLProtocol.reset()
        StubURLProtocol.stub("anime-list-full.json", json: rows)
        let bridge = AnimeIDBridge(session: StubURLProtocol.session)

        let snapshots = await withTaskGroup(of: Snapshot?.self) { group in
            for _ in 0..<5 {
                group.addTask { try? await bridge.snapshot(for: Lookup(imdbID: "tt0286390")) }
            }
            return await group.reduce(into: [Snapshot?]()) { $0.append($1) }
        }

        #expect(StubURLProtocol.requested.count == 1, "one download, however many callers")
        #expect(snapshots.count == 5)
        for snapshot in snapshots {
            #expect(try #require(snapshot).ids.aniList == 290, "a double index makes this nil")
        }
    }

    @Test func aBroadcastIDBecomesAnimeIDs() async throws {
        let bridge = AnimeIDBridge()
        await bridge.index(try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8)))

        let snapshot = try #require(await bridge.snapshot(for: Lookup(imdbID: "tt0286390")))
        #expect(snapshot.ids.aniList == 290)
        #expect(snapshot.ids.myAnimeList == 290)
        #expect(snapshot.title == nil, "the bridge supplies ids and nothing else")
    }

    @Test func aSharedBroadcastIDResolvesToNothingRatherThanTheFirstMatch() async throws {
        // 3x3 Eyes and its sequel share tt0102847. Choosing either would file a
        // sequel's ids onto the original, and nothing downstream would notice.
        let bridge = AnimeIDBridge()
        await bridge.index(try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8)))

        #expect(try await bridge.snapshot(for: Lookup(imdbID: "tt0102847")) == nil)
    }

    @Test func aSeasonNarrowsASharedID() async throws {
        let bridge = AnimeIDBridge()
        await bridge.index(try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8)))

        let first = try await bridge.snapshot(for: Lookup(ids: Identifiers(imdb: "tt0102847"), season: 1))
        let second = try await bridge.snapshot(for: Lookup(ids: Identifiers(imdb: "tt0102847"), season: 2))

        #expect(first?.ids.aniList == 300)
        #expect(second?.ids.aniList == 1225)
    }

    @Test func bothShapesOfEveryFieldDecode() throws {
        // imdb_id is an array on newer rows and a bare string on older ones;
        // themoviedb_id is {"tv": n} or a bare number.
        let entries = try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8))

        #expect(entries[0].imdbIDs == ["tt0286390"])
        #expect(entries[3].imdbIDs == ["tt2560140"], "bare string")
        #expect(entries[0].tmdbID == 26209, "keyed by media type")
        #expect(entries[3].tmdbID == 1429, "bare number")
    }

    @Test func aTitleTheBridgeHasNeverHeardOfIsNil() async throws {
        let bridge = AnimeIDBridge()
        await bridge.index(try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(rows.utf8)))

        #expect(try await bridge.snapshot(for: Lookup(imdbID: "tt0903747")) == nil)
    }

    @Test func anIdenticalRequestIsNotMadeTwice() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: #"{"results":[{"id":1,"name":"X","popularity":1}]}"#)
        StubURLProtocol.stub("/tv/1", json: #"{"id":1,"name":"X"}"#)

        let tmdb = TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        let after = StubURLProtocol.requested.count
        _ = try await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        #expect(StubURLProtocol.requested.count == after, "answered from the cache")
        #expect(after == 2, "and the first lookup really did make both requests")
    }

    @Test func aBodyThatDoesNotParseIsNotCached() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/search/tv", json: "{{{ not json")

        let tmdb = TMDBProvider(accessToken: "t", session: StubURLProtocol.session)
        _ = try? await tmdb.snapshot(for: Lookup(search: "X", kind: .series))
        _ = try? await tmdb.snapshot(for: Lookup(search: "X", kind: .series))

        // Caching a failure would repeat it without the round trip that might
        // have fixed it.
        #expect(StubURLProtocol.requested.count == 2)
    }
  }

    @Test func aFilmAndAShowSharingATMDBNumberAreKeptApart() async throws {
        let bridge = AnimeIDBridge()
        await bridge.index(try JSONDecoder().decode([AnimeIDBridge.Entry].self, from: Data(#"[{"anilist_id":1,"themoviedb_id":{"tv":500}},{"anilist_id":2,"themoviedb_id":{"movie":500}}]"#.utf8)))
        let show = try await bridge.snapshot(for: Lookup(ids: Identifiers(tmdb: 500), kind: .series))
        let film = try await bridge.snapshot(for: Lookup(ids: Identifiers(tmdb: 500), kind: .movie))
        #expect(show?.ids.aniList == 1)
        #expect(film?.ids.aniList == 2)
    }

    @Test func aCandidateIDCarriesItsKind() {
        let film = Candidate(ids: Identifiers(tmdb: 7), kind: .movie, title: "A", provider: .tmdb)
        let show = Candidate(ids: Identifiers(tmdb: 7), kind: .series, title: "A", provider: .tmdb)
        #expect(film.id != show.id)
    }
}
