import Foundation

/// Selección de canciones por tono con la API gratuita de Google Gemini (AI Studio).
struct GeminiRanker {
    struct Pick: Decodable { let title: String; let artist: String }
    let apiKey: String
    let preferredModel: String   // vacío = automático (flash-lite primero)
    static let fallbackModels = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.8-flash"]

    init?() {
        guard let k = Keychain.get("geminiKey"), !k.isEmpty else { return nil }
        apiKey = k
        preferredModel = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
    }

    /// Modelos que soportan generateContent con esta clave (sin el prefijo "models/").
    static func availableModels(apiKey: String) async throws -> [String] {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = j["models"] as? [[String: Any]] else { throw AppError.msg("No se pudo leer la lista de modelos de Gemini.") }
        return arr.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            .filter { $0.hasPrefix("gemini-") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("embedding") }
            .sorted()
    }

    func pick(artist: String, tone: String, count: Int, includeSimilar: Bool, candidates: [TrackInfo]) async throws -> [Pick] {
        let list = candidates.map { "- \($0.title) — \($0.artist)" }.joined(separator: "\n")
        let scope = includeSimilar
            ? "Mezcla canciones del artista (mayoría) con artistas similares que encajen con el tono."
            : "Usa SOLO canciones del artista indicado."
        let prompt = """
        Crea una lista de reproducción de exactamente \(count) canciones para el artista "\(artist)" con el tono/estado de ánimo "\(tone)". \(scope)
        Ordénalas para que la lista fluya bien. Prioriza las candidatas disponibles en Spotify (abajo) pero puedes añadir otras reales que conozcas con certeza; no inventes canciones.
        Candidatas:
        \(list.isEmpty ? "(ninguna)" : list)

        Responde SOLO con un array JSON: [{"title":"...","artist":"..."}]
        """
        let body = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json"],
        ])

        // Cadena de modelos: el elegido, o los flash-lite disponibles (menos demanda), y los de reserva.
        var chain: [String] = preferredModel.isEmpty ? [] : [preferredModel]
        if preferredModel.isEmpty {
            let all = (try? await Self.availableModels(apiKey: apiKey)) ?? []
            chain += all.filter { $0.contains("flash-lite") && !$0.contains("preview") }.reversed()
            chain += all.filter { $0.contains("flash-lite") && $0.contains("preview") }.reversed()
        }
        chain += Self.fallbackModels.filter { !chain.contains($0) }

        var data = Data(), status = 0, lastModel = ""
        for round in 0..<2 {   // si todos fallan por saturación, espera y repite la cadena una vez
            if round == 1 { try await Task.sleep(nanoseconds: 6_000_000_000) }
            for model in chain {
                var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
                req.httpMethod = "POST"
                req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = body
                let (d, r) = try await URLSession.shared.data(for: req)
                data = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; lastModel = model
                if status == 200 || ![503, 429, 404, 400].contains(status) { break }
            }
            if status == 200 { break }
        }
        guard status == 200 else {
            let hint = status == 429 ? " (límite gratuito alcanzado, espera un poco)" : ""
            throw AppError.msg("Error de Gemini \(status) con \(lastModel)\(hint): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = (((j["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]),
              let text = parts.compactMap({ $0["text"] as? String }).first,
              let s = text.firstIndex(of: "["), let e = text.lastIndex(of: "]"),
              let arr = try? JSONDecoder().decode([Pick].self, from: Data(text[s...e].utf8)) else {
            throw AppError.msg("Gemini devolvió un formato inesperado.")
        }
        return arr
    }
}
