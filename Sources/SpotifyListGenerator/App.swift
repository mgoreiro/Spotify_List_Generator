import AppKit
import SwiftData
import SwiftUI

@main
struct SpotifyListGeneratorApp: App {
    @StateObject private var spotify = SpotifyClient()
    private let container: ModelContainer?
    private let storeError: String?
    private static let storeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SpotifyListGenerator", isDirectory: true)

    init() {
        // BBDD persistente en ~/Library/Application Support; nunca se borra salvo petición expresa.
        // Si no se puede abrir, se muestra el error y NO se toca el archivo (el histórico es valioso).
        do {
            try FileManager.default.createDirectory(at: Self.storeDir, withIntermediateDirectories: true)
            let config = ModelConfiguration(url: Self.storeDir.appendingPathComponent("history.store"))
            container = try ModelContainer(for: Tone.self, GenerationRequest.self, SavedPlaylist.self, SavedTrack.self,
                                           configurations: config)
            storeError = nil
        } catch {
            container = nil
            storeError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView().environmentObject(spotify)
                    .frame(minWidth: 900, minHeight: 600)
                    .modelContainer(container)
            } else {
                StoreErrorView(message: storeError ?? "", folder: Self.storeDir).frame(width: 520, height: 260)
            }
        }
        Settings {
            if let container { SettingsView().environmentObject(spotify).modelContainer(container) }
            else { Text("La base de datos no está disponible.").padding() }
        }
    }
}

struct StoreErrorView: View {
    let message: String
    let folder: URL
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("No se pudo abrir la base de datos del histórico").font(.headline)
            Text("Tus datos no se han modificado ni borrado. Copia la carpeta de datos como respaldo antes de intentar nada más.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(message).font(.caption).textSelection(.enabled).lineLimit(4)
            Button("Mostrar carpeta de datos") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        .padding()
    }
}
