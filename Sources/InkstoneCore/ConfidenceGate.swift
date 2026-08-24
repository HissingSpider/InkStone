import Foundation

/// When a page should be sent to the cloud model.
public enum EscalationMode: String, Codable, Sendable {
    /// Never. Weak pages are still written, flagged `needs_review`.
    case off
    /// Only pages the gate judges unreliable. The sensible default once a key
    /// is configured: it pays for the pages that need it and no others.
    case lowConfidence
    /// Every page with meaningful content.
    ///
    /// For handwriting Vision simply cannot read, gating is false economy — the
    /// gate's own signals are derived from an OCR pass that is wrong throughout,
    /// so it will wave through pages that are quietly garbage. Per-page hash
    /// caching keeps the standing cost to genuinely new pages.
    case always
}

/// Why a page was — or was not — sent to the cloud model.
public struct EscalationDecision: Sendable, Equatable {
    public var shouldEscalate: Bool
    /// Blended 0...1 quality score. Lower is worse.
    public var score: Double
    public var reasons: [String]
    /// True when the local transcription should not be trusted, whether or not
    /// escalation is available to rescue it.
    public var needsReview: Bool
}

/// Decides which pages local OCR handled badly enough to be worth paying for.
///
/// Vision's own confidence is necessary but nowhere near sufficient. It reports
/// high confidence on a page it barely read, because it is confident about the
/// six words it did find and silent about the rest — and it reports high
/// confidence on words it got wrong, because every glyph it chose was a
/// plausible letter. So the gate blends four independent signals, and the
/// lexical one is the only one that can tell "Adding 2 vectors" from
/// "Abling 2 vedur".
public struct ConfidenceGate: Sendable {

    public var threshold: Double
    public var mode: EscalationMode
    public var lexicon: Lexicon

    /// Pages with fewer characters than this are treated as blank, not as
    /// failures — a divider page should never cost an API call.
    public var blankPageCharacterFloor = 12

    /// Above this share of unrecognisable words, the page is not language.
    public var unknownWordThreshold = 0.40

    public init(config: InkstoneConfig, lexicon: Lexicon = .system) {
        self.threshold = config.escalationThreshold
        self.mode = config.resolvedEscalationMode
        self.lexicon = lexicon
    }

    public init(threshold: Double = 0.55, mode: EscalationMode = .lowConfidence,
                lexicon: Lexicon = .system) {
        self.threshold = threshold
        self.mode = mode
        self.lexicon = lexicon
    }

    /// `inkCoverage` is the share of the page covered in ink, from the diagram
    /// pass. Pass nil when it has not been computed; the coverage signal is
    /// then skipped rather than guessed at.
    public func evaluate(_ transcript: PageTranscript, inkCoverage: Double? = nil) -> EscalationDecision {
        var reasons: [String] = []

        guard transcript.characterCount >= blankPageCharacterFloor else {
            return EscalationDecision(shouldEscalate: false, score: 1.0,
                                      reasons: ["page is blank or near-blank"],
                                      needsReview: false)
        }

        let confidence = transcript.confidence
        if confidence < threshold {
            reasons.append(String(format: "mean confidence %.2f below %.2f", confidence, threshold))
        }

        // A page where a third of the lines are shaky is unreliable even if the
        // weighted mean squeaks over the line.
        let weakLines = transcript.lines.filter { $0.confidence < threshold }.count
        let weakFraction = transcript.lines.isEmpty
            ? 0 : Double(weakLines) / Double(transcript.lines.count)
        if weakFraction > 0.34 {
            reasons.append(String(format: "%.0f%% of lines below threshold", weakFraction * 100))
        }

        let garbage = Self.garbageRatio(transcript)
        if garbage > 0.22 {
            reasons.append(String(format: "%.0f%% of characters are not letters or digits", garbage * 100))
        }

        // The signal the others cannot provide: is this language at all?
        let text = transcript.lines.map(\.text).joined(separator: " ")
        let unknownRatio = lexicon.unknownWordRatio(of: text)
        var lexicalScore = 1.0
        if let unknownRatio {
            lexicalScore = max(0, 1 - unknownRatio / unknownWordThreshold * 0.5)
            if unknownRatio > unknownWordThreshold {
                reasons.append(String(format: "%.0f%% of words are not recognisable words",
                                      unknownRatio * 100))
            }
        }

        // Lots of ink, very little text: Vision looked at the page and mostly
        // gave up. This is the signal that catches dense cursive.
        var coverageScore = 1.0
        if let inkCoverage, inkCoverage > 0.04 {
            let charactersPerInk = Double(transcript.characterCount) / inkCoverage
            coverageScore = min(1.0, charactersPerInk / 4_000)
            if coverageScore < 0.5 {
                reasons.append("dense ink but little recognised text")
            }
        }

        let score = 0.35 * confidence
            + 0.15 * (1 - weakFraction)
            + 0.10 * (1 - min(garbage / 0.4, 1))
            + 0.15 * coverageScore
            + 0.25 * lexicalScore

        let needsReview = score < threshold || !reasons.isEmpty

        let shouldEscalate: Bool
        switch mode {
        case .off: shouldEscalate = false
        case .lowConfidence: shouldEscalate = needsReview
        case .always: shouldEscalate = true
        }

        if mode == .off && needsReview {
            reasons.append("cloud escalation disabled — flagged for review instead")
        }
        return EscalationDecision(
            shouldEscalate: shouldEscalate,
            score: (score * 1000).rounded() / 1000,
            reasons: reasons,
            needsReview: needsReview)
    }

    /// Share of characters that are neither letters, digits, nor ordinary
    /// punctuation — the fingerprint of OCR that has lost the plot.
    static func garbageRatio(_ transcript: PageTranscript) -> Double {
        let text = transcript.lines.map(\.text).joined()
        guard !text.isEmpty else { return 0 }
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".,;:!?'\"()[]{}-–—/\\%$&*+=<>#@^_|~`"))
        let bad = text.unicodeScalars.filter { !allowed.contains($0) }.count
        return Double(bad) / Double(text.unicodeScalars.count)
    }
}
