import Foundation
import Testing

// The two Localizable.strings files, checked against each other and against
// the keys the source actually references. Files are read from the repository
// (via #filePath), not from a bundle: the point is to catch a key added to
// one language and not the other, or referenced and never added, before it
// ships as a raw key on screen.
struct LocalizationTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // kikiyakuTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func stringsEntries(_ lang: String) throws -> [String: String] {
        let url = repoRoot.appending(path: "Sources/kikiyaku/Resources/\(lang).lproj/Localizable.strings")
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        let line = /^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";/
        for raw in content.split(separator: "\n") {
            if let match = raw.matches(of: line).first {
                entries[String(match.1)] = String(match.2)
            }
        }
        return entries
    }

    /// %@ / %d, positional or not. Positions default to the order of
    /// appearance, so "%1$@ and %2$d" and "%@ and %d" describe the same
    /// arguments.
    private static func formatSpecifiers(_ value: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var nextPosition = 1
        for match in value.matches(of: /%(?:(\d+)\$)?([@d])/) {
            let position = match.1.flatMap { Int($0) } ?? nextPosition
            result[position] = String(match.2)
            nextPosition = max(nextPosition, position) + 1
        }
        return result
    }

    @Test func bothLanguagesDefineTheSameKeys() throws {
        let en = try Self.stringsEntries("en")
        let ja = try Self.stringsEntries("ja")
        let missingInJa = Set(en.keys).subtracting(ja.keys).sorted()
        let missingInEn = Set(ja.keys).subtracting(en.keys).sorted()
        #expect(missingInJa.isEmpty, "keys missing in ja: \(missingInJa)")
        #expect(missingInEn.isEmpty, "keys missing in en: \(missingInEn)")
    }

    @Test func formatArgumentsAgreeAcrossLanguages() throws {
        let en = try Self.stringsEntries("en")
        let ja = try Self.stringsEntries("ja")
        for (key, enValue) in en {
            guard let jaValue = ja[key] else { continue }
            #expect(
                Self.formatSpecifiers(enValue) == Self.formatSpecifiers(jaValue),
                "format mismatch for \(key): en \"\(enValue)\" vs ja \"\(jaValue)\"")
        }
    }

    @Test func everyReferencedKeyExists() throws {
        let en = try Self.stringsEntries("en")
        let ja = try Self.stringsEntries("ja")
        let sources = Self.repoRoot.appending(path: "Sources/kikiyaku")
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var referenced: Set<String> = []
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for match in content.matches(of: /\bLF?\("([^"]+)"/) {
                referenced.insert(String(match.1))
            }
        }
        let unresolved = referenced.subtracting(en.keys).union(referenced.subtracting(ja.keys)).sorted()
        #expect(unresolved.isEmpty, "referenced but not defined: \(unresolved)")
    }
}
