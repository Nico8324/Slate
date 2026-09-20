import Foundation

/// Turns a TMDB, IMDb or TVDB id into the AniList, MyAnimeList and AniDB ids
/// that anime services answer to.
///
/// Anime lives under two id systems that do not meet. TMDB and IMDb number the
/// broadcast; AniList, MAL and AniDB number the work. Nothing in either system
/// bridges to the other, which is why finding an anime by name is the only route
/// Slate otherwise has — and why a title with an unusual romanisation can be
/// found by neither.
///
/// [Fribb/anime-lists](https://github.com/Fribb/anime-lists) publishes the
/// bridge as one file. Fetched once, projected down to id pairs and the rest
/// discarded: the download is about 7.5 MB and the useful part of it is a few
/// hundred kilobytes.
///
/// **The mapping is many-to-one in the direction this queries.** Two AniDB
/// entries routinely share an IMDb id — `3x3 Eyes` and its sequel do — so an
/// IMDb id resolves to a *set* of anime. ``snapshot(for:)`` returns the entry
/// that matches most narrowly and `nil` when it cannot choose, rather than the
/// first of several — narrow it with ``Lookup/season``.
public actor AnimeIDBridge: MetadataProvider {
    public nonisolated let provider = Provider.fribb

    /// The published list. Pinned to `master` deliberately: a stale bridge is
    /// worse than a slow one — it silently misses everything released since.
    public static let listURL = URL(
        string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json"
    )!

    private let session: URLSession
    private var byIMDb: [String: [Entry]] = [:]
    /// TMDB numbers films and shows separately, so a TV id and a film id can
    /// be the same number: one map for each, and a bare number (the list
    /// doesn't say which) in both.
    private var byTMDBTV: [Int: [Entry]] = [:]
    private var byTMDBMovie: [Int: [Entry]] = [:]
    private var loaded = false
    private var loading: Task<Void, any Error>?

    /// Hold **one instance for the life of the app**, and add it to
    /// ``MetadataAggregator`` alongside the other providers — it is in no default
    /// set, so the id → bridge → AniList chain is off until a caller puts it
    /// there.
    ///
    /// The one-instance rule costs more here than anywhere else in Slate. A
    /// provider built per lookup is merely unpaced; a *bridge* built per lookup
    /// downloads 7.5 MB per lookup, because the index it builds is the instance.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// What the bridge knows about one title, or `nil` when it holds nothing or
    /// cannot choose between several candidates.
    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        // Only anime ids — no titles, no metadata. This provider exists to make
        // *other* providers reachable.
        guard lookup.ids.aniList == nil || lookup.ids.myAnimeList == nil else { return nil }
        guard let entry = try await entry(for: lookup) else { return nil }

        return Snapshot(ids: Identifiers(aniList: entry.anilist_id, myAnimeList: entry.mal_id))
    }

    func entry(for lookup: Lookup) async throws -> Entry? {
        try await load()

        var candidates: [Entry] = []
        if let imdb = lookup.ids.imdb { candidates = byIMDb[imdb] ?? [] }
        if candidates.isEmpty, let tmdb = lookup.ids.tmdb {
            switch lookup.kind {
            case .movie: candidates = byTMDBMovie[tmdb] ?? []
            case .series: candidates = byTMDBTV[tmdb] ?? []
            case nil:
                let both = (byTMDBTV[tmdb] ?? []) + (byTMDBMovie[tmdb] ?? [])
                candidates = both.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            }
        }
        guard !candidates.isEmpty else {
            Log.bridge.debug("no entry for \(Log.describe(lookup.ids), privacy: .public)")
            return nil
        }
        if candidates.count == 1 { return candidates.first }

        // Several works share this broadcast id. A season number narrows it
        // where the list states one; otherwise the honest answer is that the id
        // does not identify a work, and picking the first would file a sequel's
        // ids onto the original.
        if let season = lookup.season {
            // TMDB's numbering first and TheTVDB's only where that says
            // nothing: the two count seasons differently, and mixing them in
            // one test let a TVDB season 2 answer for a TMDB season 2.
            let byTMDBSeason = candidates.filter { $0.season?.tmdb == season }
            if byTMDBSeason.count == 1 { return byTMDBSeason.first }
            if byTMDBSeason.isEmpty {
                let byTVDBSeason = candidates.filter { $0.season?.tmdb == nil && $0.season?.tvdb == season }
                if byTVDBSeason.count == 1 { return byTVDBSeason.first }
            }
        }
        // The refusal a consumer most needs told apart from the two silences
        // either side of it. "I hold nothing for this id" and "I hold several
        // and will not choose" are the same `nil` from outside, and the second
        // is fixable by the caller — `Lookup.season` narrows it.
        Log.bridge.notice(
            """
            \(candidates.count, privacy: .public) works share \
            \(Log.describe(lookup.ids), privacy: .public); refusing to choose\
            \(lookup.season == nil ? " — pass Lookup.season to narrow it" : "", privacy: .public)
            """
        )
        return nil
    }

    /// Fetches and indexes once, however many callers arrive at once.
    ///
    /// The download is the whole reason this needs saying. `guard !loaded` alone
    /// does not hold across the `await`: the suspension releases the actor, so
    /// every concurrent caller passes the guard and starts its own 7.5 MB fetch —
    /// and a library scan, which is the only workload that asks about several
    /// anime at once, is exactly that case. Worse than the bandwidth, ``index(_:)``
    /// appends, so a second pass files every entry twice and every id then
    /// resolves to two candidates and therefore to `nil`. The bridge would go
    /// quiet for everything.
    ///
    /// So the *task* is the shared state, not the flag: the first caller starts
    /// it, the rest await the same one. A failure is not remembered — `loading`
    /// is cleared either way — because a fetch that failed is worth retrying,
    /// unlike one that succeeded.
    private func load() async throws {
        if loaded { return }
        if let loading { return try await loading.value }
        let task = Task { try await fetchAndIndex() }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func fetchAndIndex() async throws {
        guard !loaded else { return }
        // The one large fetch in the package, and the one a consumer cannot
        // otherwise see happening — it is lazy, it is 7.5 MB, and before 0.10.1
        // it could silently happen once per concurrent caller. One line at each
        // end makes "did this download, how often, and what did it hold" a
        // question the log answers.
        Log.bridge.notice("loading the id bridge — \(Self.listURL.lastPathComponent, privacy: .public)")
        let (data, response) = try await session.data(from: Self.listURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Log.bridge.error("id bridge failed — HTTP \(http.statusCode, privacy: .public)")
            throw SlateError.http(status: http.statusCode, body: "")
        }
        // Row by row: one malformed entry used to fail the whole file and
        // switch the bridge off for the session.
        index(try JSONDecoder().decode([LossyEntry].self, from: data).compactMap(\.entry))
        Log.bridge.notice(
            """
            id bridge ready — \(data.count, privacy: .public) bytes, \
            \(self.byIMDb.count, privacy: .public) imdb ids, \
            \(self.byTMDBTV.count + self.byTMDBMovie.count, privacy: .public) tmdb ids
            """
        )
    }

    func index(_ entries: [Entry]) {
        // Replace, never append. Appending is what makes a second pass fatal
        // rather than wasteful: every id would then hold two candidates, and
        // `entry(for:)` refuses to choose between two — so the bridge would go
        // quiet for everything while looking like a provider that knows nothing.
        // Cheaper to make the second pass harmless than to prove it unreachable.
        byIMDb.removeAll()
        byTMDBTV.removeAll()
        byTMDBMovie.removeAll()
        for entry in entries where entry.anilist_id != nil || entry.mal_id != nil {
            for imdb in entry.imdbIDs { byIMDb[imdb, default: []].append(entry) }
            switch entry.themoviedb_id {
            case .bare(let id)?:
                byTMDBTV[id, default: []].append(entry)
                byTMDBMovie[id, default: []].append(entry)
            case .keyed(let tv, let movie)?:
                if let tv { byTMDBTV[tv, default: []].append(entry) }
                if let movie { byTMDBMovie[movie, default: []].append(entry) }
            case nil: break
            }
        }
        loaded = true
    }

    /// A row that decodes to `nil` rather than failing the list.
    private struct LossyEntry: Decodable {
        let entry: Entry?
        init(from decoder: any Decoder) { entry = try? Entry(from: decoder) }
    }

    /// One row of the published list, keeping only the ids and the season number
    /// that disambiguates them. Everything else in the file — titles, synonyms,
    /// tags, pictures — is dropped as it is decoded.
    public struct Entry: Decodable, Sendable, Equatable {
        public var anilist_id: Int?
        public var mal_id: Int?
        public var anidb_id: Int?
        public var thetvdb_id: Int?
        var imdb: IMDbField?
        var themoviedb_id: TMDBField?
        var season: Season?

        struct Season: Decodable, Equatable {
            var tvdb: Int?
            var tmdb: Int?
        }

        /// `imdb_id` is an array — several IMDb ids can map to one entry — but
        /// older rows carry a bare string.
        enum IMDbField: Decodable, Equatable {
            case one(String)
            case many([String])

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) { self = .many(list) }
                else { self = .one(try container.decode(String.self)) }
            }

            var values: [String] {
                switch self {
                case .one(let value): [value]
                case .many(let values): values
                }
            }
        }

        /// `themoviedb_id` is `{"tv": 1429}` or `{"movie": 603}`, and sometimes
        /// a bare number.
        enum TMDBField: Decodable, Equatable {
            case bare(Int)
            case keyed(tv: Int?, movie: Int?)

            private struct Keyed: Decodable { var tv: Int?; var movie: Int? }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Int.self) { self = .bare(value) }
                else {
                    let keyed = try container.decode(Keyed.self)
                    self = .keyed(tv: keyed.tv, movie: keyed.movie)
                }
            }

            var value: Int? {
                switch self {
                case .bare(let value): value
                case .keyed(let tv, let movie): tv ?? movie
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case anilist_id, mal_id, anidb_id, thetvdb_id, themoviedb_id, season
            case imdb = "imdb_id"
        }

        var imdbIDs: [String] { imdb?.values ?? [] }
        var tmdbID: Int? { themoviedb_id?.value }
    }
}
