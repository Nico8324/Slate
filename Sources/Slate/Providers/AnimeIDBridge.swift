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
/// IMDb id resolves to a *set* of anime. ``identifiers(for:)`` returns the entry
/// that matches most narrowly and `nil` when it cannot choose, rather than the
/// first of several.
public actor AnimeIDBridge: MetadataProvider {
    public nonisolated let provider = Provider.fribb

    /// The published list. Pinned to `master` deliberately: a stale bridge is
    /// worse than a slow one — it silently misses everything released since.
    public static let listURL = URL(
        string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json"
    )!

    private let session: URLSession
    private var byIMDb: [String: [Entry]] = [:]
    private var byTMDB: [Int: [Entry]] = [:]
    private var loaded = false

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
        if candidates.isEmpty, let tmdb = lookup.ids.tmdb { candidates = byTMDB[tmdb] ?? [] }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates.first }

        // Several works share this broadcast id. A season number narrows it
        // where the list states one; otherwise the honest answer is that the id
        // does not identify a work, and picking the first would file a sequel's
        // ids onto the original.
        if let season = lookup.season {
            let matching = candidates.filter { $0.season?.tmdb == season || $0.season?.tvdb == season }
            if matching.count == 1 { return matching.first }
        }
        return nil
    }

    private func load() async throws {
        guard !loaded else { return }
        let (data, response) = try await session.data(from: Self.listURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SlateError.http(status: http.statusCode, body: "")
        }
        index(try JSONDecoder().decode([Entry].self, from: data))
    }

    func index(_ entries: [Entry]) {
        for entry in entries where entry.anilist_id != nil || entry.mal_id != nil {
            for imdb in entry.imdbIDs { byIMDb[imdb, default: []].append(entry) }
            if let tmdb = entry.tmdbID { byTMDB[tmdb, default: []].append(entry) }
        }
        loaded = true
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
