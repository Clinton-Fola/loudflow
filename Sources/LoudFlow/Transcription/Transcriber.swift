import Foundation

enum TranscriberError: Error {
    case missingKey
    case auth
    case credit
    case network
    case server(Int)
    case decoding
    case tooLarge
}

struct TranscriptionResult {
    var text: String
    var turns: [Turn]?

    static func plain(_ text: String) -> TranscriptionResult { .init(text: text, turns: nil) }
}

struct TranscriptionHints {
    static let spellingsKey = "transcription.spellings"
    static let multilingualKey = "transcription.deepgramMultilingual"
    let terms: [String]
    let multilingual: Bool

    // Bound the encoded size conservatively for both providers' token limits.
    init?(spellings: String, multilingual: Bool) {
        var seen = Set<String>()
        let terms = spellings.components(separatedBy: CharacterSet(charactersIn: ",").union(.newlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard terms.joined(separator: ", ").utf8.count <= 400,
              terms.allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "<>").union(.controlCharacters)) == nil })
        else { return nil }
        self.terms = terms
        self.multilingual = multilingual
    }

    static var saved: TranscriptionHints {
        let defaults = UserDefaults.standard
        let multilingual = defaults.bool(forKey: multilingualKey)
        return TranscriptionHints(spellings: defaults.string(forKey: spellingsKey) ?? "", multilingual: multilingual)
            ?? TranscriptionHints(terms: [], multilingual: multilingual)
    }

    private init(terms: [String], multilingual: Bool) {
        self.terms = terms
        self.multilingual = multilingual
    }
}

protocol Transcriber {
    func transcribe(_ audioURL: URL, twoTrack: Bool, hints: TranscriptionHints) async throws -> TranscriptionResult
    func validateKey() async -> Bool
}

enum TranscriberFactory {
    static func make(provider: Provider) -> Transcriber {
        switch provider {
        case .deepgram: return DeepgramTranscriber()
        case .whisper:  return WhisperTranscriber()
        }
    }
}

extension Transcriber {
    // Long meetings upload for a while and the provider then works through the whole file.
    static var requestTimeout: TimeInterval { 600 }

    func mapStatus(_ code: Int) -> TranscriberError {
        switch code {
        case 401, 403: return .auth
        case 402:      return .credit
        case 413:      return .tooLarge
        case 429:      return .credit
        default:       return .server(code)
        }
    }
}
