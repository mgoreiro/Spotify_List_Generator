import AppKit
import CryptoKit
import Foundation
import Network

enum AppError: LocalizedError {
    case msg(String)
    /// La playlist se creó en Spotify pero no se pudieron añadir todas las canciones.
    case partialPlaylist(id: String, url: String, added: Int, reason: String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        case .partialPlaylist(_, let url, let added, let reason):
            return "La playlist se creó en Spotify pero solo se añadieron \(added) canciones (\(reason)). Revísala o bórrala desde Spotify: \(url)"
        }
    }
}

/// Autenticación PKCE (redirect loopback) + llamadas a la Web API de Spotify.
@MainActor
final class SpotifyClient: ObservableObject {
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = "playlist-modify-private playlist-modify-public user-modify-playback-state user-read-playback-state"

    @Published var isConnected = false
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "spotifyClientID") }
    }

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var listener: NWListener?

    init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        isConnected = Keychain.get("spotifyRefresh") != nil
    }

    // MARK: Auth

    func connect() async throws {
        guard !clientID.isEmpty else { throw AppError.msg("Introduce el Client ID de Spotify en Ajustes.") }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        async let code = waitForCallback(expectedState: state)
        try await Task.sleep(nanoseconds: 200_000_000)
        NSWorkspace.shared.open(c.url!)
        let authCode = try await code
        try await tokenRequest(["grant_type": "authorization_code", "code": authCode,
                                "redirect_uri": Self.redirectURI, "client_id": clientID,
                                "code_verifier": verifier])
    }

    func disconnect() {
        Keychain.set(nil, for: "spotifyRefresh")
        accessToken = nil
        isConnected = false
    }

    private func waitForCallback(expectedState: String) async throws -> String {
        // Solo loopback: otros equipos de la red no pueden conectar con el listener.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 8888)
        let l = try NWListener(using: params)
        listener = l
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            func finish(_ r: Result<String, Error>) {
                guard !done else { return }
                done = true
                l.cancel()
                cont.resume(with: r)
            }
            l.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    func reply(_ status: String, _ text: String) {
                        let body = "<html><body style='font-family:-apple-system;text-align:center;margin-top:20%'><h2>\(text)</h2></body></html>"
                        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                    }
                    let req = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let comps = URLComponents(string: "http://x" + path)
                    let items = comps?.queryItems ?? []
                    func value(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
                    // Cualquier cosa que no sea el callback con nuestro "state" se ignora sin abortar el login.
                    guard comps?.path == "/callback", value("state") == expectedState else {
                        reply("400 Bad Request", "Petición no válida."); return
                    }
                    if let code = value("code") {
                        reply("200 OK", "Conectado. Ya puedes volver a la app.")
                        finish(.success(code))
                    } else if value("error") != nil {
                        reply("200 OK", "Autorización denegada. Puedes cerrar esta pestaña.")
                        finish(.failure(AppError.msg("Autorización denegada en Spotify.")))
                    } else {
                        reply("400 Bad Request", "Petición no válida.")
                    }
                }
            }
            l.stateUpdateHandler = { if case .failed(let e) = $0 { finish(.failure(e)) } }
            l.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { finish(.failure(AppError.msg("Tiempo de espera agotado."))) }
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let token = json?["access_token"] as? String else {
            // Solo un invalid_grant significa que el refresh token ya no sirve; un 5xx/429/red es transitorio.
            if json?["error"] as? String == "invalid_grant" {
                Keychain.set(nil, for: "spotifyRefresh"); isConnected = false
            }
            throw AppError.msg("No se pudo autenticar con Spotify (\(status)): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        let j = json ?? [:]
        accessToken = token
        expiry = Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 60)
        if let r = j["refresh_token"] as? String { Keychain.set(r, for: "spotifyRefresh") }
        isConnected = true
    }

    private func validToken() async throws -> String {
        if let t = accessToken, expiry > .now { return t }
        guard let refresh = Keychain.get("spotifyRefresh") else { throw AppError.msg("Conecta con Spotify primero.") }
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        return accessToken!
    }

    // MARK: HTTP

    @discardableResult
    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        for attempt in 0..<3 {
            var req = URLRequest(url: c.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429, attempt < 2 {
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2
                // Esperas largas (cuota agotada) no se bloquean: se informa al usuario.
                guard wait <= 30 else {
                    throw AppError.msg("Spotify pide esperar \(Int(wait)) s por el límite de uso. Inténtalo más tarde.")
                }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); continue
            }
            guard (200..<300).contains(status) else {
                throw AppError.msg("Spotify \(method) \(path) → \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        throw AppError.msg("Spotify: demasiados reintentos")
    }

    // MARK: API

    func searchArtist(_ name: String) async throws -> (id: String, name: String)? {
        let j = try await call("GET", "/search", query: ["q": name, "type": "artist", "limit": "1"])
        guard let a = ((j["artists"] as? [String: Any])?["items"] as? [[String: Any]])?.first,
              let id = a["id"] as? String, let n = a["name"] as? String else { return nil }
        return (id, n)
    }

    private func parse(_ t: [String: Any]) -> TrackInfo? {
        guard let uri = t["uri"] as? String, let title = t["name"] as? String else { return nil }
        let artists = (t["artists"] as? [[String: Any]]) ?? []
        return TrackInfo(uri: uri, title: title,
                         artist: artists.compactMap { $0["name"] as? String }.joined(separator: ", "),
                         artistIDs: artists.compactMap { $0["id"] as? String },
                         album: (t["album"] as? [String: Any])?["name"] as? String ?? "",
                         durationMs: t["duration_ms"] as? Int ?? 0)
    }

    /// La búsqueda de Spotify limita a 10 resultados por página en apps nuevas.
    func searchTracks(query: String, pages: Int = 1) async throws -> [TrackInfo] {
        var out: [TrackInfo] = []
        for p in 0..<pages {
            let j = try await call("GET", "/search", query: ["q": query, "type": "track", "limit": "10", "offset": "\(p * 10)"])
            let items = ((j["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            out += items.compactMap(parse)
            if items.isEmpty { break }
        }
        return out
    }

    func createPlaylist(name: String, description: String, uris: [String]) async throws -> (id: String, url: String) {
        let p = try await call("POST", "/me/playlists", body: ["name": name, "description": description, "public": false])
        guard let id = p["id"] as? String else { throw AppError.msg("Spotify no devolvió el id de la playlist.") }
        let url = (p["external_urls"] as? [String: Any])?["spotify"] as? String ?? "https://open.spotify.com/playlist/\(id)"
        var added = 0
        for start in stride(from: 0, to: uris.count, by: 100) {
            let chunk = Array(uris[start..<min(start + 100, uris.count)])
            do { try await call("POST", "/playlists/\(id)/items", body: ["uris": chunk]) }
            catch { throw AppError.partialPlaylist(id: id, url: url, added: added, reason: error.localizedDescription) }
            added += chunk.count
        }
        return (id, url)
    }

    func play(playlistID: String) async throws {
        try await call("PUT", "/me/player/play", body: ["context_uri": "spotify:playlist:\(playlistID)"])
    }

    /// Abre la lista en la app de escritorio (esquema spotify:); si no está instalada, cae a la web.
    static func openInDesktop(playlistID: String) {
        let app = URL(string: "spotify:playlist:\(playlistID)")!
        if !NSWorkspace.shared.open(app) {
            NSWorkspace.shared.open(URL(string: "https://open.spotify.com/playlist/\(playlistID)")!)
        }
    }

    // MARK: util

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
