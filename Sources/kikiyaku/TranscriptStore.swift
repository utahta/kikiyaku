import Foundation

/// Saves the session's (start-to-stop) utterance history as JSONL.
/// One line = one utterance as JSON; being directly consumable by jq
/// and similar tools takes priority.
enum TranscriptStore {
    /// UserDefaults key. Can also be changed with
    /// `defaults write com.utahta.kikiyaku saveDirectoryPath <path>`.
    private static let saveDirectoryKey = "saveDirectoryPath"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kikiyaku", isDirectory: true)
    }

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: saveDirectoryKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDirectory
    }

    /// Pass nil to reset to the default (Application Support/kikiyaku).
    static func setDirectory(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: saveDirectoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
        }
    }

    /// Returns the URL of the saved file, or nil (writing nothing) when there are no utterances.
    static func save(_ utterances: [Utterance]) throws -> URL? {
        guard !utterances.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.filenameStamp(Date())
        var url = directory.appendingPathComponent("kikiyaku-\(stamp).jsonl")
        // Append a sequence number so multiple saves within the same second do not overwrite.
        var sequence = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("kikiyaku-\(stamp)-\(sequence).jsonl")
            sequence += 1
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var lines: [String] = []
        for utterance in utterances {
            let record = Record(
                time: utterance.time,
                source: utterance.source,
                translation: utterance.translation,
                // Only meaningful while no final translation exists (a failed
                // final that left the provisional on screen).
                provisionalTranslation: utterance.translation == nil
                    ? utterance.provisionalTranslation : nil,
                translationEngine: utterance.translationEngine,
                confidence: utterance.confidence,
                translationSkipped: utterance.translationSkipped ? true : nil,
                translationFailed: utterance.finalTranslationFailed ? true : nil
            )
            let data = try encoder.encode(record)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct Record: Encodable {
        let time: Date
        let source: String
        let translation: String?
        let provisionalTranslation: String?
        let translationEngine: String?
        let confidence: Double?
        let translationSkipped: Bool?
        /// The final translation failed permanently. Recorded structurally —
        /// the localized failure label shown in the UI is never saved as data.
        let translationFailed: Bool?
    }

    private static func filenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
