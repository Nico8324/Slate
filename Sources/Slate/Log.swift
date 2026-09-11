import Foundation
import os

/// Slate's logging, in one place so the privacy rules are decided once.
///
/// Everything here goes to the unified log under subsystem `Slate`, so a
/// consumer filters the whole package with `subsystem:Slate` and one area of it
/// with `category:`. Nothing is printed, nothing is written to a file, and
/// nothing is retained by the package — `os.Logger` is the only dependency this
/// adds, and it is not a package one.
///
/// ## What is public and what is private
///
/// A log line is read by whoever can read the device's log, which on a
/// developer's machine is anyone holding it. So the split is not about
/// convenience:
///
/// - **Public:** catalogue ids, counts, byte totals, HTTP status codes,
///   provider names, durations, decisions. Numbers about *titles*. A log that
///   will not say which id it refused cannot be acted on, which is the whole
///   reason the bridge's logging was added in 0.10.2.
/// - **Private:** anything a person chose — a search query, a title, a URL
///   carrying either. `os.Logger` redacts these outside a debugger, so a
///   shipped app does not write its user's library into the system log.
///
/// **A credential is neither.** No interpolation anywhere in this package puts
/// a header, a token or a key into a log line, at any privacy level, and
/// ``HTTP`` logs `url.path` rather than the URL when a query string could carry
/// one. `.private` redacts for a reader; it does not stop the string being
/// built, and a token is not the kind of thing to be one debugger attach away
/// from. See ``Log/redactingQuery(_:)``.
enum Log {
    static let http = Logger(subsystem: "Slate", category: "HTTP")
    static let aggregator = Logger(subsystem: "Slate", category: "Aggregator")
    static let tmdb = Logger(subsystem: "Slate", category: "TMDB")
    static let aniList = Logger(subsystem: "Slate", category: "AniList")
    static let mdbList = Logger(subsystem: "Slate", category: "MDBList")
    static let bridge = Logger(subsystem: "Slate", category: "AnimeIDBridge")
    static let seasons = Logger(subsystem: "Slate", category: "Seasons")
    static let artwork = Logger(subsystem: "Slate", category: "Artwork")

    /// The ids and shape a lookup carries, never what was typed.
    ///
    /// A query is the one part of a ``Lookup`` that belongs to a person rather
    /// than to a catalogue, so it is reported only as present or absent. Every
    /// line that needs to identify *which* lookup uses this.
    static func describe(_ lookup: Lookup) -> String {
        var parts = [describe(lookup.ids)]
        if lookup.query != nil { parts.append("by name") }
        if let kind = lookup.kind { parts.append(kind.rawValue) }
        if let season = lookup.season { parts.append("season \(season)") }
        if let year = lookup.year { parts.append(String(year)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Catalogue ids, safe at any privacy level — numbers about a title, never
    /// about a person.
    static func describe(_ ids: Identifiers) -> String {
        [ids.imdb, ids.tmdb.map { "tmdb:\($0)" }, ids.aniList.map { "anilist:\($0)" },
         ids.myAnimeList.map { "mal:\($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty ?? "no ids"
    }

    /// A URL reduced to the part that is safe at any privacy level: host and
    /// path, never the query.
    ///
    /// TMDB puts the search term in `?query=`, and MDBList's other spelling of
    /// authentication is `?apikey=` — which this package deliberately does not
    /// use, but a log helper is exactly the wrong place to assume that stays
    /// true. Dropping the query removes both hazards at once and leaves the
    /// half that identifies which endpoint was called.
    static func redactingQuery(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }
        components.queryItems = nil
        components.fragment = nil
        return components.string ?? url.path
    }
}

extension Duration {
    /// Whole milliseconds, for a log line that should not carry eighteen digits
    /// of attoseconds.
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
