import Foundation

struct DeepgramTranscriber: Transcriber {
    private static let base = "https://api.deepgram.com/v1/listen"
    private static let common =
        "model=nova-3&punctuate=true&paragraphs=true&smart_format=true&mip_opt_out=true"

    // diarize=true is pinned to Deepgram's v1 diarizer; diarize_model=latest picks the current one.
    private static let diarizer = "diarize_model=latest"
    private static let legacyDiarizer = "diarize=true"

    static func endpoint(twoTrack: Bool, diarizer: String, hints: TranscriptionHints) -> URL {
        var url = URLComponents(string: "\(base)?\(common)&\(diarizer)")!
        var items = url.queryItems ?? []
        if twoTrack { items.append(URLQueryItem(name: "multichannel", value: "true")) }
        if hints.multilingual { items.append(URLQueryItem(name: "language", value: "multi")) }
        if !hints.terms.isEmpty {
            items.append(URLQueryItem(name: "redact_usage", value: "true"))
            items += hints.terms.map { URLQueryItem(name: "keyterm", value: $0) }
        }
        url.queryItems = items
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }

    private var apiKey: String? { Keychain.key(for: .deepgram) }

    func transcribe(_ audioURL: URL, twoTrack: Bool, hints: TranscriptionHints) async throws -> TranscriptionResult {
        guard let key = apiKey else { throw TranscriberError.missingKey }
        guard let audio = try? Data(contentsOf: audioURL) else { throw TranscriberError.decoding }

        let data: Data
        do {
            data = try await send(audio, key: key, to: Self.endpoint(twoTrack: twoTrack, diarizer: Self.diarizer, hints: hints))
        } catch TranscriberError.server(400) {
            data = try await send(audio, key: key, to: Self.endpoint(twoTrack: twoTrack, diarizer: Self.legacyDiarizer, hints: hints))
        }

        guard let decoded = try? JSONDecoder().decode(DeepgramResponse.self, from: data),
              let channels = decoded.results?.channels, !channels.isEmpty
        else { throw TranscriberError.decoding }

        return Self.result(from: channels, twoTrack: twoTrack)
    }

    private func send(_ audio: Data, key: String, to url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        req.httpMethod = "POST"
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: req, from: audio)
        } catch {
            throw TranscriberError.network
        }

        guard let http = response as? HTTPURLResponse else { throw TranscriberError.network }
        guard (200..<300).contains(http.statusCode) else { throw mapStatus(http.statusCode) }
        return data
    }

    func validateKey() async -> Bool {
        guard let key = apiKey else { return false }
        var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    static func result(from channels: [DeepgramResponse.Channel], twoTrack: Bool) -> TranscriptionResult {
        let timed = channels.map { channel in
            (channel.alternatives?.first?.words ?? []).map { w in
                let start = w.start ?? 0
                return TimedWord(text: w.punctuated_word ?? w.word ?? "",
                                 start: start,
                                 end: max(start, w.end ?? start),
                                 speaker: w.speaker ?? 0)
            }
        }

        let transcripts = channels.map {
            ($0.alternatives?.first?.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // If one side has text but no usable words, timing cannot establish its
        // place in the conversation. Keep both sides in channel order.
        if timed.indices.contains(where: { i in
            !transcripts[i].isEmpty && !timed[i].contains { !$0.text.isEmpty }
        }) {
            let parts = timed.indices.map { i in
                transcripts[i].isEmpty ? timed[i].map(\.text).filter { !$0.isEmpty }.joined(separator: " ") : transcripts[i]
            }
            return .plain(parts.filter { !$0.isEmpty }.joined(separator: " "))
        }

        let result = TurnBuilder.build(channels: timed, twoTrack: twoTrack)
        if channels.count == 1, result.turns == nil, !transcripts[0].isEmpty {
            return .plain(transcripts[0])
        }
        return result
    }
}

// MARK: - Response shape (only the fields we read)

struct DeepgramResponse: Decodable {
    struct Results: Decodable { let channels: [Channel]? }
    struct Channel: Decodable { let alternatives: [Alternative]? }
    struct Alternative: Decodable {
        let transcript: String?
        let words: [Word]?
    }
    struct Word: Decodable {
        let word: String?
        let punctuated_word: String?
        let start: TimeInterval?
        let end: TimeInterval?
        let speaker: Int?
    }
    let results: Results?
}
