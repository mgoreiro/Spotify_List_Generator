import AppKit
import Foundation

/// Exporta el histórico completo (peticiones + listas) a JSON o CSV como copia de seguridad.
enum Exporter {
    enum Format { case json, csv }

    private struct TrackOut: Codable { let position: Int; let title: String; let artist: String; let album: String; let uri: String; let durationMs: Int }
    private struct RequestOut: Codable {
        let date: Date; let artist: String; let tone: String; let count: Int; let includeSimilar: Bool; let seedSong: String?
        let status: String; let error: String?; let playlistName: String?; let playlistURL: String?; let tracks: [TrackOut]
    }

    private static func rows(_ requests: [GenerationRequest]) -> [RequestOut] {
        requests.sorted { $0.createdAt < $1.createdAt }.map { r in
            RequestOut(date: r.createdAt, artist: r.artist, tone: r.tone, count: r.count, includeSimilar: r.includeSimilar, seedSong: r.seedSong,
                       status: r.status, error: r.errorMessage, playlistName: r.playlist?.name, playlistURL: r.playlist?.spotifyURL,
                       tracks: (r.playlist?.sortedTracks ?? []).map {
                           TrackOut(position: $0.position + 1, title: $0.title, artist: $0.artist, album: $0.album, uri: $0.uri, durationMs: $0.durationMs)
                       })
        }
    }

    static func data(_ requests: [GenerationRequest], format: Format) throws -> Data {
        let rows = rows(requests)
        switch format {
        case .json:
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            return try enc.encode(rows)
        case .csv:
            // Texto entrecomillado; los que empiezan por = + - @ se neutralizan para que Excel/Numbers no los evalúe.
            func q(_ s: String) -> String {
                var v = s
                if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let iso = ISO8601DateFormatter()
            var out = "fecha,artista_pedido,tono,canciones_pedidas,cancion_referencia,estado,posicion,titulo,artista,album,uri,duracion_ms,playlist_url,error\n"
            for r in rows {
                let head = [iso.string(from: r.date), q(r.artist), q(r.tone), "\(r.count)", q(r.seedSong ?? ""), r.status]
                let tail = [q(r.playlistURL ?? ""), q(r.error ?? "")]
                if r.tracks.isEmpty {
                    out += (head + ["", "", "", "", "", ""] + tail).joined(separator: ",") + "\n"
                }
                for t in r.tracks {
                    out += (head + ["\(t.position)", q(t.title), q(t.artist), q(t.album), t.uri, "\(t.durationMs)"] + tail)
                        .joined(separator: ",") + "\n"
                }
            }
            return Data(out.utf8)
        }
    }

    @MainActor
    static func save(_ requests: [GenerationRequest], format: Format) {
        let panel = NSSavePanel()
        let ext = format == .json ? "json" : "csv"
        panel.nameFieldStringValue = "historico-spotify-lists.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data(requests, format: format).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}
