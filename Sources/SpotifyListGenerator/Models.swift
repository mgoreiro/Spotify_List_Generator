import Foundation
import SwiftData

/// Tono/mood disponible en el selector. Se guardan en BBDD para poder añadir/editar.
@Model
final class Tone {
    @Attribute(.unique) var name: String
    var isBuiltIn: Bool
    init(name: String, isBuiltIn: Bool = true) {
        self.name = name
        self.isBuiltIn = isBuiltIn
    }

    static let defaults = [
        "Tristes", "Alegres", "Románticas", "Para bailar", "Relajadas", "Energéticas",
        "Nostálgicas", "Para concentrarse", "Para entrenar", "Fiesta", "Melancólicas",
        "Para dormir", "Viaje en carretera", "Cena tranquila", "Desamor", "Verano",
    ]
}

/// Una petición del usuario (queda en el histórico aunque falle).
@Model
final class GenerationRequest {
    var id: UUID
    var createdAt: Date
    var artist: String
    var tone: String
    var count: Int
    var includeSimilar: Bool
    var status: String        // pending | done | failed
    var errorMessage: String?
    @Relationship(deleteRule: .cascade, inverse: \SavedPlaylist.request)
    var playlist: SavedPlaylist?

    init(artist: String, tone: String, count: Int, includeSimilar: Bool) {
        self.id = UUID()
        self.createdAt = .now
        self.artist = artist
        self.tone = tone
        self.count = count
        self.includeSimilar = includeSimilar
        self.status = "pending"
    }
}

@Model
final class SavedPlaylist {
    var id: UUID
    var name: String
    var createdAt: Date
    var spotifyPlaylistID: String?
    var spotifyURL: String?
    var request: GenerationRequest?
    @Relationship(deleteRule: .cascade, inverse: \SavedTrack.playlist)
    var tracks: [SavedTrack] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
    }

    var sortedTracks: [SavedTrack] { tracks.sorted { $0.position < $1.position } }
}

@Model
final class SavedTrack {
    var position: Int
    var title: String
    var artist: String
    var album: String
    var uri: String
    var durationMs: Int
    var playlist: SavedPlaylist?

    init(position: Int, title: String, artist: String, album: String, uri: String, durationMs: Int) {
        self.position = position
        self.title = title
        self.artist = artist
        self.album = album
        self.uri = uri
        self.durationMs = durationMs
    }
}

struct TrackInfo: Hashable {
    let uri: String
    let title: String
    let artist: String
    let artistIDs: [String]
    let album: String
    let durationMs: Int
}
