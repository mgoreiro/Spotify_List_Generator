import Foundation
import SwiftData

/// Pipeline híbrido: candidatas desde Spotify (búsqueda por artista) + Gemini para
/// seleccionar/ordenar según el tono y proponer canciones adicionales; todo se resuelve en Spotify.
@MainActor
struct Generator {
    let spotify: SpotifyClient
    let context: ModelContext

    func run(artist: String, tone: String, count: Int, includeSimilar: Bool) async {
        let req = GenerationRequest(artist: artist, tone: tone, count: count, includeSimilar: includeSimilar)
        context.insert(req)
        try? context.save()   // la petición queda registrada aunque falle
        var built: [TrackInfo] = []
        let name = "\(artist) · \(tone) (\(count))"
        func store(_ tracks: [TrackInfo], id: String, url: String) {
            let pl = SavedPlaylist(name: name)
            pl.spotifyPlaylistID = id
            pl.spotifyURL = url
            pl.tracks = tracks.enumerated().map {
                SavedTrack(position: $0.offset, title: $0.element.title, artist: $0.element.artist,
                           album: $0.element.album, uri: $0.element.uri, durationMs: $0.element.durationMs)
            }
            req.playlist = pl
        }
        do {
            built = try await build(artist: artist, tone: tone, count: count, includeSimilar: includeSimilar)
            let created = try await spotify.createPlaylist(
                name: name, description: "Generada por Spotify List Generator — \(tone)", uris: built.map(\.uri))
            store(built, id: created.id, url: created.url)
            req.status = "done"
            if built.count < count { req.errorMessage = "Solo se encontraron \(built.count) canciones distintas de \(count) pedidas." }
        } catch AppError.partialPlaylist(let id, let url, let added, let reason) {
            // La playlist existe en Spotify: se registra lo añadido para no dejarla huérfana ni duplicarla al reintentar.
            store(Array(built.prefix(added)), id: id, url: url)
            req.status = "failed"
            req.errorMessage = AppError.partialPlaylist(id: id, url: url, added: added, reason: reason).errorDescription
        } catch {
            req.status = "failed"
            req.errorMessage = error.localizedDescription
        }
        try? context.save()
    }

    private func build(artist: String, tone: String, count: Int, includeSimilar: Bool) async throws -> [TrackInfo] {
        guard let found = try await spotify.searchArtist(artist) else {
            throw AppError.msg("No se encontró el artista “\(artist)” en Spotify.")
        }
        // 1) Candidatas del artista: varias búsquedas (por décadas) para superar el límite de resultados.
        //    Se agrupan por canción "base" (sin Remastered/Remix/Live/Feat.) y se conserva la mejor versión.
        let want = max(count * 2, 40)
        var best: [String: TrackInfo] = [:]
        var order: [String] = []
        let queries = ["artist:\"\(found.name)\"", "artist:\"\(found.name)\" year:2020-2030",
                       "artist:\"\(found.name)\" year:2010-2019", "artist:\"\(found.name)\" year:2000-2009",
                       "artist:\"\(found.name)\" year:1990-1999", "artist:\"\(found.name)\" year:1980-1989",
                       "artist:\"\(found.name)\" year:1900-1979"]
        var searchError: Error?
        for q in queries where order.count < want {
            let batch: [TrackInfo]
            do { batch = try await spotify.searchTracks(query: q, pages: 5) }
            catch { searchError = searchError ?? error; continue }
            for t in batch where t.artistIDs.contains(found.id) {
                let k = Self.baseTitle(t.title)
                if let cur = best[k] {
                    if Self.variantScore(t) < Self.variantScore(cur) { best[k] = t }
                } else { best[k] = t; order.append(k) }
            }
        }
        let candidates = order.compactMap { best[$0] }
        // Si no hay ni una candidata y hubo errores, el problema es la API (sesión, límite, red), no el artista.
        if candidates.isEmpty, let e = searchError { throw e }

        guard let ranker = GeminiRanker() else {
            // Sin clave de Gemini: solo candidatas del artista, sin criterio de tono. Originales primero.
            guard !candidates.isEmpty else { throw AppError.msg("Sin resultados para ese artista.") }
            return Array(candidates.enumerated().sorted {
                (Self.variantScore($0.element), $0.offset) < (Self.variantScore($1.element), $1.offset)
            }.map(\.element).prefix(count))
        }
        // 2) Gemini elige entre las candidatas y propone extras.
        let picks = try await ranker.pick(artist: found.name, tone: tone, count: count,
                                          includeSimilar: includeSimilar, candidates: candidates)
        var result: [TrackInfo] = []
        var seen = Set<String>()   // títulos base + artista principal ya incluidos
        func add(_ t: TrackInfo) {
            let id = Self.baseTitle(t.title) + "|" + (t.artistIDs.first ?? t.artist)
            if seen.insert(id).inserted { result.append(t) }
        }
        for p in picks {
            if let t = best[Self.baseTitle(p.title)], Self.sameArtist(p.artist, found.name) { add(t) }
            else if let t = try? await resolve(p, mainArtist: found, includeSimilar: includeSimilar) { add(t) }
            if result.count == count { break }
        }
        // 3) Rellena con candidatas si faltan (originales antes que versiones).
        for c in candidates.sorted(by: { Self.variantScore($0) < Self.variantScore($1) }) where result.count < count { add(c) }
        guard !result.isEmpty else { throw AppError.msg("No se pudo construir la lista.") }
        return result
    }

    /// Resuelve una propuesta de Gemini en Spotify. Solo acepta resultados cuyo título base y artista
    /// coinciden con la propuesta (Spotify devuelve aproximaciones), y prefiere la versión original.
    private func resolve(_ p: GeminiRanker.Pick, mainArtist: (id: String, name: String), includeSimilar: Bool) async throws -> TrackInfo? {
        let wantTitle = Self.baseTitle(p.title)
        let wantArtist = Self.fold(p.artist.isEmpty ? mainArtist.name : p.artist)
        let artistName = p.artist.isEmpty ? mainArtist.name : p.artist
        let r = try await spotify.searchTracks(query: "track:\"\(p.title)\" artist:\"\(artistName)\"")
            .filter { Self.baseTitle($0.title) == wantTitle }
            .filter { t in
                if !includeSimilar { return t.artistIDs.contains(mainArtist.id) }   // modo estricto: solo el artista pedido
                let a = Self.fold(t.artist)
                return a.contains(wantArtist) || wantArtist.contains(a) || t.artistIDs.contains(mainArtist.id)
            }
        return r.min { Self.variantScore($0) < Self.variantScore($1) }
    }

    // MARK: Normalización de títulos

    /// Marcadores de versión. Con límites de palabra para no acertar en "Democracia", "Alive" o "Mixtura".
    private static let variantWords = #"\b(?:remaster(?:ed)?|remix(?:es)?|mix|live|en vivo|en directo|versions?|edit|acoustic|acustic[oa]?|radio edit|demo|deluxe|bonus|instrumental|karaoke|sessions?|unplugged|mono|stereo|original|medley|(?:19|20)\d\d)\b"#
    private static let strongVariant = #"\b(?:remix(?:es)?|live|en vivo|en directo|karaoke|instrumental|acoustic|acustic[oa]?|unplugged|sessions?|demo)\b"#

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// "Frío, Frío - 2025 Remastered" y "Estrellitas y Duendes Feat. Sting" → título base comparable.
    static func baseTitle(_ title: String) -> String {
        var t = fold(title)
        t = t.replacingOccurrences(of: #"\s[-–]\s.*("# + variantWords + #").*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*("# + variantWords + #"|feat|ft\.|with)[^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s(feat|ft|featuring)\b.*$"#, with: "", options: .regularExpression)
        // Conserva letras y números de cualquier alfabeto (japonés, cirílico, árabe…), no solo ASCII.
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
        let base = t.split(separator: " ").joined(separator: " ")
        // Si el título era solo signos, no colapsar todo en "": usa el título original normalizado.
        return base.isEmpty ? fold(title).trimmingCharacters(in: .whitespaces) : base
    }

    /// Texto entre paréntesis/corchetes y tras " - " (donde van "Remastered", "Live", "Feat."…).
    private static func segments(_ folded: String) -> String {
        var parts: [String] = []
        let ns = folded as NSString
        if let re = try? NSRegularExpression(pattern: #"[\(\[]([^\)\]]*)[\)\]]"#) {
            for m in re.matches(in: folded, range: NSRange(location: 0, length: ns.length)) { parts.append(ns.substring(with: m.range(at: 1))) }
        }
        if let r = folded.range(of: #"\s[-–]\s.*$"#, options: .regularExpression) { parts.append(String(folded[r])) }
        return parts.joined(separator: " | ")
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        return x.isEmpty || x.contains(y) || y.contains(x)
    }

    /// 0 = original, 1 = remaster/otras ediciones, 2 = remix/directo/medley/acústico.
    /// Solo se miran los segmentos de versión del título (no palabras sueltas como "Live and Let Die")
    /// y, del álbum, únicamente marcadores claros.
    static func variantScore(_ t: TrackInfo) -> Int {
        let title = fold(t.title), album = fold(t.album)
        let seg = segments(title)
        if matches(seg, strongVariant) || matches(title, #"\bmedley\b"#) || matches(album, strongVariant) { return 2 }
        if matches(seg, variantWords) || matches(seg, #"\b(?:feat|ft|featuring)\b"#)
            || matches(title, #"\s(?:feat|ft|featuring)\b"#) || matches(album, #"\bremaster(?:ed)?\b"#) { return 1 }
        return 0
    }
}
