import Foundation

extension TMDBProvider {

    /// Every poster, backdrop and logo TMDB holds, in every language.
    ///
    /// Deliberately unfiltered. TMDB can filter by language server-side, but the
    /// choosing rules live in ``ArtworkSet/best(_:preferring:)`` where they can
    /// be reasoned about — and asking for one language means a second request
    /// when it turns out to have none, which for a picker is the wrong shape
    /// entirely.
    ///
    /// - Parameter ids: Identifiers for the title whose artwork is requested.
    /// - Parameter kind: Whether the title is a movie or a series.
    /// - Parameter nativeSeason: **TMDB's own** season number, not one from a
    ///   corrected ``SeasonStructure``. Translate first with
    ///   ``SeasonStructure/nativeSeason(ofSeason:)``. Bleach's arc season 2 lives
    ///   inside TMDB's season 1, so passing 2 straight through returns
    ///   Thousand-Year Blood War's posters — a real picture of the wrong season,
    ///   with nothing in the result to say so.
    public func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int? = nil) async throws -> ArtworkSet? {
        try Task.checkCancellation()
        try Lookup(ids: ids, season: nativeSeason).validate()
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        let path: String
        switch (kind, nativeSeason) {
        case (.movie, _):
            // Not `ids.tmdb` alone: a film that arrived by IMDb id had no TMDB
            // id yet, and this returned nothing rather than looking it up — the
            // television path had done the lookup all along.
            guard let id = try await movieID(for: ids) else { return nil }
            path = "/movie/\(id)/images"
        case (.series, let nativeSeason?):
            guard let id = try await showID(for: ids) else { return nil }
            path = "/tv/\(id)/season/\(nativeSeason)/images"
        case (.series, nil):
            guard let id = try await showID(for: ids) else { return nil }
            path = "/tv/\(id)/images"
        }

        Log.artwork.debug("fetching \(path, privacy: .public)")
        let payload = try await http.json(Images.self,
                                          url: try URL.build(Self.api, path: path),
                                          headers: headers)
        return payload.artworkSet
    }

    struct Images: Decodable {
        struct Item: Decodable {
            let file_path: String
            var iso_639_1: String?
            var vote_average: Double?
            var width: Int?
            var height: Int?

            func artwork(_ kind: ArtworkKind) -> Artwork? {
                // `file_path` is third-party JSON. Percent-encoded rather than
                // interpolated raw: an unencoded `?` or `#` could not escape the
                // pinned host, but it would silently become a query or a fragment
                // and fetch something other than the picture asked for.
                guard let url = TMDBProvider.imageURL(file_path)
                else { return nil }
                return Artwork(
                    kind: kind, url: url,
                    // TMDB says "" for an image with no text; that is textless,
                    // not a language called empty string.
                    language: iso_639_1?.nilIfEmpty,
                    width: width, height: height, rating: vote_average, provider: .tmdb
                )
            }
        }
        var posters: [Item]?
        var backdrops: [Item]?
        var logos: [Item]?

        var artworkSet: ArtworkSet {
            ArtworkSet(
                posters: posters?.compactMap { $0.artwork(.poster) } ?? [],
                backdrops: backdrops?.compactMap { $0.artwork(.backdrop) } ?? [],
                logos: logos?.compactMap { $0.artwork(.logo) } ?? []
            )
        }
    }
}
