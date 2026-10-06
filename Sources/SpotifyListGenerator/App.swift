import SwiftData
import SwiftUI

@main
struct SpotifyListGeneratorApp: App {
    @StateObject private var spotify = SpotifyClient()
    let container: ModelContainer

    init() {
        // BBDD persistente en ~/Library/Application Support; nunca se borra salvo petición expresa.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyListGenerator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: dir.appendingPathComponent("history.store"))
        container = try! ModelContainer(for: Tone.self, GenerationRequest.self, SavedPlaylist.self, SavedTrack.self,
                                        configurations: config)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(spotify)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(container)
        Settings { SettingsView().environmentObject(spotify) }
            .modelContainer(container)
    }
}
