import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var spotify: SpotifyClient
    @Query(sort: \GenerationRequest.createdAt, order: .reverse) private var history: [GenerationRequest]
    @Query(sort: \Tone.name) private var tones: [Tone]

    @State private var artist = ""
    @State private var tone = "Tristes"
    @State private var count = 20
    @State private var includeSimilar = false
    @State private var busy = false
    @State private var selection: GenerationRequest?
    @State private var toDelete: GenerationRequest?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(history) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.artist).font(.headline)
                            if r.status == "failed" { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                        Text("\(r.tone) · \(r.count) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(r)
                    .contextMenu { Button("Eliminar…", role: .destructive) { toDelete = r } }
                }
            }
            .navigationTitle("Histórico")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Menu("Exportar", systemImage: "square.and.arrow.up") {
                        Button("Histórico completo (JSON)") { Exporter.save(history, format: .json) }
                        Button("Histórico completo (CSV)") { Exporter.save(history, format: .csv) }
                    }.disabled(history.isEmpty)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                form.padding()
                Divider()
                if let r = selection { DetailView(request: r, tones: tones.map(\.name), busy: busy, requestDelete: { toDelete = r },
                                           regenerate: { t, c, sim in run(artist: r.artist, tone: t, count: c, similar: sim) }) }
                else { ContentUnavailableView("Selecciona una petición del histórico", systemImage: "music.note.list") }
            }
        }
        .confirmationDialog("¿Eliminar esta petición y su lista del histórico?",
                            isPresented: .init(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let r = toDelete { if selection == r { selection = nil }; context.delete(r); try? context.save() }
                toDelete = nil
            }
        } message: { Text("Solo se borra de la base de datos local; la playlist de Spotify no se elimina.") }
        .onAppear(perform: seedTones)
    }

    private var form: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading) { Text("Artista").font(.caption); TextField("Juan Luis Guerra", text: $artist).frame(minWidth: 180) }
            VStack(alignment: .leading) {
                Text("Tono").font(.caption)
                Picker("", selection: $tone) { ForEach(tones.map(\.name), id: \.self) { Text($0).tag($0) } }.labelsHidden()
            }
            VStack(alignment: .leading) {
                Text("Canciones").font(.caption)
                Picker("", selection: $count) { ForEach([10, 20, 50], id: \.self) { Text("\($0)").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            Toggle("Incluir similares", isOn: $includeSimilar)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Generar lista") { generate() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || artist.trimmingCharacters(in: .whitespaces).isEmpty || !spotify.isConnected)
            if !spotify.isConnected { Text("Conecta Spotify en Ajustes (⌘,)").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func generate() {
        run(artist: artist.trimmingCharacters(in: .whitespaces), tone: tone, count: count, similar: includeSimilar)
    }

    private func run(artist: String, tone: String, count: Int, similar: Bool) {
        busy = true
        Task {
            await Generator(spotify: spotify, context: context).run(artist: artist, tone: tone, count: count, includeSimilar: similar)
            selection = history.first
            busy = false
        }
    }

    private func seedTones() {
        guard tones.isEmpty else { return }
        Tone.defaults.forEach { context.insert(Tone(name: $0)) }
        try? context.save()
    }
}

struct DetailView: View {
    @EnvironmentObject var spotify: SpotifyClient
    let request: GenerationRequest
    let tones: [String]
    let busy: Bool
    let requestDelete: () -> Void
    let regenerate: (String, Int, Bool) -> Void
    @State private var message: String?
    @State private var showRegen = false
    @State private var regenTone = ""
    @State private var regenCount = 20
    @State private var regenSimilar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(request.artist) — \(request.tone)").font(.title2.bold())
                    Text("\(request.count) canciones pedidas · \(request.createdAt.formatted())").foregroundStyle(.secondary)
                }
                Spacer()
                if let pl = request.playlist {
                    Button("Reproducir", systemImage: "play.fill") {
                        Task {
                            let id = pl.spotifyPlaylistID ?? ""
                            do { try await spotify.play(playlistID: id); message = nil }
                            catch {
                                // Sin dispositivo activo: abre la app de escritorio con la lista.
                                SpotifyClient.openInDesktop(playlistID: id)
                                message = "No había reproductor activo; he abierto la lista en Spotify, pulsa Play allí."
                            }
                        }
                    }
                    if let id = pl.spotifyPlaylistID {
                        Button("Abrir en Spotify", systemImage: "arrow.up.forward.app") { SpotifyClient.openInDesktop(playlistID: id) }
                    }
                }
                Button("Regenerar…", systemImage: "arrow.clockwise") {
                    regenTone = request.tone; regenCount = request.count; regenSimilar = request.includeSimilar
                    showRegen = true
                }
                .disabled(busy || !spotify.isConnected)
                .popover(isPresented: $showRegen) { regenForm }
                Button("Eliminar", role: .destructive, action: requestDelete)
            }
            if let m = message ?? request.errorMessage { Text(m).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if let pl = request.playlist {
                Table(pl.sortedTracks) {
                    TableColumn("#") { Text("\($0.position + 1)") }.width(30)
                    TableColumn("Título", value: \.title)
                    TableColumn("Artista", value: \.artist)
                    TableColumn("Álbum", value: \.album)
                    TableColumn("Dur.") { Text(String(format: "%d:%02d", $0.durationMs / 60000, ($0.durationMs / 1000) % 60)) }.width(50)
                }
            } else { Spacer() }
        }
        .padding()
    }
}

extension DetailView {
    /// Repite la petición con otro tono / número de canciones; crea una entrada nueva en el histórico.
    var regenForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nueva lista para \(request.artist)").font(.headline)
            Picker("Tono", selection: $regenTone) {
                ForEach(tones.contains(regenTone) ? tones : tones + [regenTone], id: \.self) { Text($0).tag($0) }
            }
            Picker("Canciones", selection: $regenCount) { ForEach([10, 20, 50], id: \.self) { Text("\($0)").tag($0) } }
                .pickerStyle(.segmented)
            Toggle("Incluir similares", isOn: $regenSimilar)
            HStack { Spacer(); Button("Generar") { showRegen = false; regenerate(regenTone, regenCount, regenSimilar) }.keyboardShortcut(.defaultAction) }
        }
        .padding().frame(width: 300)
    }
}

extension SavedTrack: Identifiable {}

struct SettingsView: View {
    @EnvironmentObject var spotify: SpotifyClient
    @State private var geminiKey = Keychain.get("geminiKey") ?? ""
    @State private var geminiModel = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
    @Environment(\.modelContext) private var context
    @Query(sort: \Tone.name) private var tones: [Tone]
    @State private var newTone = ""
    @State private var models: [String] = []
    @State private var error: String?

    var body: some View {
        Form {
            Section("Spotify") {
                TextField("Client ID", text: $spotify.clientID)
                Text("Redirect URI a registrar: \(SpotifyClient.redirectURI)").font(.caption).textSelection(.enabled)
                HStack {
                    Button(spotify.isConnected ? "Reconectar" : "Conectar") {
                        Task { do { try await spotify.connect(); error = nil } catch { self.error = error.localizedDescription } }
                    }
                    if spotify.isConnected { Button("Desconectar") { spotify.disconnect() }; Text("Conectado").foregroundStyle(.green) }
                }
            }
            Section("Google Gemini (selección por tono, plan gratuito)") {
                HStack {
                    SecureField("API key", text: $geminiKey).onSubmit(saveGeminiKey)
                    Button("Guardar", action: saveGeminiKey)
                }
                Picker("Modelo", selection: $geminiModel) {
                    Text("Automático (flash-lite primero)").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                    if !geminiModel.isEmpty && !models.contains(geminiModel) { Text(geminiModel).tag(geminiModel) }
                }
                .onChange(of: geminiModel) { _, v in UserDefaults.standard.set(v, forKey: "geminiModel") }
                Button("Cargar modelos disponibles") {
                    Task {
                        do { models = try await GeminiRanker.availableModels(apiKey: geminiKey); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(geminiKey.isEmpty)
                Link("Obtener clave gratis en aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
                Text("Sin clave, la lista usa solo las canciones del artista sin criterio de tono.").font(.caption)
            }
            Section("Tonos") {
                HStack {
                    TextField("Nuevo tono (p. ej. “Para estudiar”)", text: $newTone).onSubmit(addTone)
                    Button("Añadir", action: addTone).disabled(newTone.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(tones) { t in
                    HStack {
                        Text(t.name)
                        if !t.isBuiltIn { Text("propio").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Quitar", systemImage: "minus.circle") { context.delete(t); try? context.save() }
                            .buttonStyle(.borderless).labelStyle(.iconOnly).disabled(tones.count <= 1)
                    }
                }
                Button("Restaurar tonos por defecto") {
                    for n in Tone.defaults where !tones.contains(where: { $0.name == n }) { context.insert(Tone(name: n)) }
                    try? context.save()
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped).frame(width: 480, height: 640).padding()
        .onDisappear(perform: saveGeminiKey)
    }
}

extension SettingsView {
    /// Se guarda al confirmar o al cerrar Ajustes (no por pulsación) y solo si cambió.
    func saveGeminiKey() {
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != (Keychain.get("geminiKey") ?? "") else { return }
        if Keychain.set(key, for: "geminiKey") { error = nil }
        else { error = "No se pudo guardar la clave en el Llavero." }
    }

    func addTone() {
        let n = newTone.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !tones.contains(where: { $0.name.lowercased() == n.lowercased() }) else { return }
        context.insert(Tone(name: n, isBuiltIn: false))
        try? context.save()
        newTone = ""
    }
}
