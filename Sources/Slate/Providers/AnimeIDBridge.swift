import Foundation

/// Turns a TMDB or IMDb id into AniList and MyAnimeList ids.
///
/// Anime lives under two id systems that do not meet. TMDB and IMDb number the
/// broadcast; AniList, MAL and AniDB number the work. Nothing in either system
/// bridges to the other, which is why finding an anime by name is the only route
/// Slate otherwise has — and why a title with an unusual romanisation can be
/// found by neither.
///
/// [Fribb/anime-lists](https://github.com/Fribb/anime-lists) publishes the
/// bridge as one file. Fetched lazily with a configurable lifetime, projected
/// down to id pairs, with the rest discarded: the download is about 7.5 MB and the useful part of it is a few
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

    private let transport: HTTP.Transport
    /// The raw list and its ETag are kept here, so a launch revalidates instead of downloading.
    private let directory: URL?
    private var byIMDb: [String: [Entry]] = [:]
    /// TMDB numbers films and shows separately, so a TV id and a film id can
    /// be the same number: one map for each, and a bare number (the list
    /// doesn't say which) in both.
    private var byTMDBTV: [Int: [Entry]] = [:]
    private var byTMDBMovie: [Int: [Entry]] = [:]
    private var byAniList: [Int: Entry] = [:]
    private var loaded = false
    /// Holds the download only until it is indexed, so a caller arriving just
    /// after it finished reuses it rather than downloading again.
    private let downloads = ResponseCache(limit: 1, ttl: 60, byteLimit: 64 * 1024 * 1024)
    private let lifetime: Duration
    private var expires: ContinuousClock.Instant?
    private var generation = 0

    /// Hold **one instance for the life of the app**, and add it to
    /// ``MetadataAggregator`` alongside the other providers — it is in no default
    /// set, so the id → bridge → AniList chain is off until a caller puts it
    /// there.
    ///
    /// The one-instance rule costs more here than anywhere else in Slate. A
    /// provider built per lookup is merely unpaced; a *bridge* built per lookup
    /// downloads 7.5 MB per lookup, because the index it builds is the instance.
    /// - Parameter session: Session used for requests.
    /// - Parameter cacheTTL: Index lifetime in seconds; defaults to 24 hours.
    ///   Zero disables retention. Finite values are clamped to 0…365 days;
    ///   non-finite values use the default. Refresh occurs on demand. The list is
    ///   kept on disk in `Caches/Slate/fribb` and revalidated with its ETag.
    public init(session: URLSession = .shared, cacheTTL: TimeInterval = 86_400) {
        self.init(cacheTTL: cacheTTL, transport: { try await session.data(for: $0) },
                  directory: ResponseCache.directory(for: .fribb))
    }

    init(cacheTTL: TimeInterval = 86_400, transport: @escaping HTTP.Transport, directory: URL? = nil) {
        self.transport = transport
        self.directory = directory
        self.lifetime = .seconds(cacheTTL.isFinite ? min(max(0, cacheTTL), 31_536_000) : 86_400)
    }

    /// What the bridge knows about one title, or `nil` when it holds nothing or
    /// cannot choose between several candidates.
    /// Discard the index and cancel any pending download.
    public func clearCache() async {
        generation += 1
        loaded = false
        expires = nil
        byIMDb.removeAll()
        byTMDBTV.removeAll()
        byTMDBMovie.removeAll()
        await downloads.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    public func snapshot(for lookup: Lookup) async throws -> Snapshot? {
        try Task.checkCancellation()
        try lookup.validate()
        // Only anime ids — no titles, no metadata. This provider exists to make
        // *other* providers reachable.
        guard lookup.ids.aniList == nil || lookup.ids.myAnimeList == nil else { return nil }
        guard let entry = try await entry(for: lookup) else { return nil }

        return Snapshot(ids: Identifiers(aniList: entry.anilist_id, myAnimeList: entry.mal_id))
    }

    func entry(for lookup: Lookup) async throws -> Entry? {
        guard lookup.ids.imdb != nil || lookup.ids.tmdb != nil else { return nil }
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

    /// The broadcast ids — IMDb and TMDB — of the work AniList numbers `id`, the
    /// direction ``snapshot(for:)`` does not go.
    ///
    /// Several AniList works map to one TMDB show — each season of *Attack on Titan*
    /// is its own AniList entry and one TMDB series — so the answer is the show, and
    /// `season` is the TMDB season that work is, where the list states it.
    ///
    /// - Parameter kind: Picks the TMDB film or show id when an entry carries both.
    public func broadcastIDs(ofAniList id: Int, kind: Kind) async throws -> (ids: Identifiers, season: Int?)? {
        try await load()
        guard let entry = byAniList[id] else { return nil }
        let tmdb: Int? = switch entry.themoviedb_id {
        // A bare number doesn't say whether it numbers a film or a show, and TMDB numbers
        // them separately: read as a film it named unrelated films. Only a show takes it;
        // a film goes by its IMDb id instead.
        case .bare(let value)?: kind == .series ? value : nil
        case .keyed(let tv, let movie)?: kind == .movie ? (movie ?? tv) : (tv ?? movie)
        case nil: nil
        }
        let ids = Identifiers(imdb: entry.imdbIDs.first, tmdb: tmdb, aniList: id, myAnimeList: entry.mal_id).validated
        guard ids.tmdb != nil || ids.imdb != nil else { return nil }
        return (ids, entry.season?.tmdb)
    }

    /// Share one download; cancelling a caller leaves other waiters running.
    private func load() async throws {
        try Task.checkCancellation()
        if loaded, let expires, expires > .now { return }
        let revision = generation
        let (transport, directory, fresh) = (self.transport, self.directory, loaded ? nil : lifetime)
        let data: Data
        do {
            data = try await downloads.data(for: "bridge") {
                try await Self.download(transport, directory: directory, reuseFor: fresh)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch where loaded {
            // An index a day old is still right for nearly every title; a failed
            // refresh used to throw it away and answer nothing at all.
            Log.bridge.error("refresh failed (\(Log.describe(error), privacy: .public)); keeping the previous index")
            return
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        if loaded, let expires, expires > .now { return }
        do {
            index(try JSONDecoder().decode([LossyEntry].self, from: data).compactMap(\.entry))
        } catch {
            // Never keep a list that does not parse.
            if let directory { try? FileManager.default.removeItem(at: directory) }
            await downloads.remove("bridge")
            throw error
        }
        await downloads.remove("bridge")
    }

    /// The list, from disk when it is younger than `reuseFor`, else revalidated
    /// against the saved ETag: a 304 reuses the file.
    static func download(_ transport: HTTP.Transport, directory: URL?, reuseFor lifetime: Duration?) async throws -> Data {
        let file = directory?.appending(path: "anime-list-full.json")
        let tag = directory?.appending(path: "anime-list-full.etag")
        let saved = file.flatMap { try? Data(contentsOf: $0) }
        if let file, let saved, let lifetime,
           let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified.addingTimeInterval(TimeInterval(lifetime.components.seconds)) > .now {
            return saved
        }
        var request = URLRequest(url: listURL, cachePolicy: .reloadIgnoringLocalCacheData)
        if saved != nil, let etag = tag.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await transport(request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304, let file, let saved {
            Log.bridge.debug("list unchanged, reusing the saved copy")
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            return saved
        }
        if let http, !(200..<300).contains(http.statusCode) {
            throw SlateError.http(status: http.statusCode, body: "")
        }
        if let directory, let file, let tag {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            if let etag = http?.value(forHTTPHeaderField: "ETag") {
                try? etag.write(to: tag, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: tag)
            }
        }
        return data
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
        byAniList.removeAll()
        for entry in entries where entry.anilist_id != nil || entry.mal_id != nil {
            if let aniList = entry.anilist_id, byAniList[aniList] == nil { byAniList[aniList] = entry }
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
        expires = .now.advanced(by: lifetime)
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
