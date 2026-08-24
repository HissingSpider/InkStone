import Foundation

/// A word list used to judge whether OCR output is language or noise.
///
/// This is the signal that catches the failure the other checks miss. Vision can
/// return "Abling 2 vedur" for "Adding 2 vectors" with high confidence and a
/// clean character profile: every glyph is a plausible letter, so neither the
/// confidence score nor the garbage-character ratio objects. Only asking whether
/// the words are *words* catches it.
public struct Lexicon: Sendable {

    private let words: Set<String>

    public static let system: Lexicon = {
        Lexicon(loadingFrom: URL(fileURLWithPath: "/usr/share/dict/words"))
    }()

    public init(words: Set<String>) {
        self.words = words
    }

    /// Loads a newline-separated word list. A missing file yields an empty
    /// lexicon, which disables the signal rather than failing the run — not
    /// every macOS install ships `/usr/share/dict/words`.
    public init(loadingFrom url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log.debug("no system dictionary at \(url.path); lexical check disabled")
            words = []
            return
        }
        words = Set(text.split(separator: "\n").map { $0.lowercased() })
    }

    public var isAvailable: Bool { !words.isEmpty }

    public func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }

    /// Share of `text`'s checkable tokens that are not recognisable words.
    ///
    /// Returns nil when there is nothing worth judging — no dictionary, or too
    /// few long tokens for the ratio to mean anything. A page of equations is
    /// mostly symbols and single letters and must not be condemned for it.
    public func unknownWordRatio(of text: String) -> Double? {
        guard isAvailable else { return nil }

        let tokens = Self.checkableTokens(in: text)
        // Below a handful of tokens the ratio is noise: one unrecognised proper
        // noun in three words would read as 33% garbage.
        guard tokens.count >= 6 else { return nil }

        let unknown = tokens.filter { !contains($0) }.count
        return Double(unknown) / Double(tokens.count)
    }

    /// Tokens long enough to be worth checking against a dictionary.
    ///
    /// Short tokens are excluded deliberately. Handwritten notes are full of
    /// variable names, units and abbreviations — `dx`, `cm`, `Fig`, `iff` — and
    /// a three-letter token carries almost no evidence either way. Anything with
    /// a digit is skipped too: it is a coordinate or a measurement, not a word.
    static func checkableTokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.count >= 4 }
            .filter { $0.allSatisfy(\.isLetter) }
    }
}
