import Foundation

extension TMDBProvider: ArtworkProvider {

    /// Every poster, backdrop and logo TMDB holds, in every language.
    ///
    /// Deliberately unfiltered. TMDB can filter by language server-side, but the
    /// choosing rules live in ``ArtworkSet/best(_:preferring:)`` where they can
    /// be reasoned about — and asking for one language means a second request
    /// when it turns out to have none, which for a picker is the wrong shape
    /// entirely.
    public func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int? = nil) async throws -> ArtworkSet? {
        guard !accessToken.isEmpty else { throw SlateError.missingCredential(.tmdb) }

        let path: String
        switch (kind, nativeSeason) {
        case (.movie, _):
            guard let id = ids.tmdb else { return nil }
            path = "/movie/\(id)/images"
        case (.series, let nativeSeason?):
            guard let id = try await showID(for: ids) else { return nil }
            path = "/tv/\(id)/season/\(nativeSeason)/images"
        case (.series, nil):
            guard let id = try await showID(for: ids) else { return nil }
            path = "/tv/\(id)/images"
        }

        let payload = try await http.json(Images.self,
                                          url: try URL.build(Self.api, path: path),
                                          headers: headers)
        return ArtworkSet(
            posters: payload.posters?.compactMap { $0.artwork(.poster) } ?? [],
            backdrops: payload.backdrops?.compactMap { $0.artwork(.backdrop) } ?? [],
            logos: payload.logos?.compactMap { $0.artwork(.logo) } ?? []
        )
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
                guard let encoded = file_path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: "\(TMDBProvider.images)/original\(encoded)")
                else { return nil }
                return Artwork(
                    kind: kind, url: url,
                    // TMDB says "" for an image with no text; that is textless,
                    // not a language called empty string.
                    language: iso_639_1?.nilIfEmpty,
                    width: width, height: height, rating: vote_average, provider: .tmdb,
                    sizingBase: TMDBProvider.images, path: encoded
                )
            }
        }
        var posters: [Item]?
        var backdrops: [Item]?
        var logos: [Item]?
    }
}

extension AniListProvider: ArtworkProvider {
    /// AniList holds one cover and one banner per entry, and no language or
    /// rating for either. They are worth having because AniList's cover is the
    /// one anime viewers recognise, but there is nothing here to choose between.
    public func artwork(for ids: Identifiers, kind: Kind, nativeSeason: Int? = nil) async throws -> ArtworkSet? {
        guard nativeSeason == nil, let id = ids.aniList else { return nil }
        guard let snapshot = try await snapshot(for: Lookup(ids: Identifiers(aniList: id))) else {
            return nil
        }
        return ArtworkSet(
            posters: snapshot.posterURL.map { [Artwork(kind: .poster, url: $0, provider: .aniList)] } ?? [],
            backdrops: snapshot.backdropURL.map { [Artwork(kind: .backdrop, url: $0, provider: .aniList)] } ?? []
        )
    }
}
