import Foundation

/// Why a page was — or was not — sent to the cloud model.
public struct EscalationDecision: Sendable, Equatable {
    public var shouldEscalate: Bool
    /// Blended 0...1 quality score. Lower is worse.
    public var score: Double
    public var reasons: [String]
}

/// Decides which pages local OCR handled badly enough to be worth paying for.
///
/// Vision's own confidence is necessary but not sufficient. It reports high
/// confidence on a page it barely read, because it is confident about the six
/// words it did find and silent about the rest. So the gate blends three
/// signals: how sure Vision was, how much of the page it left unread, and how
/// much of what it returned looks like garbage rather than language.
public struct ConfidenceGate: Sendable {

    public var threshold: Double
    public var enabled: Bool

    /// Pages with fewer characters than this are treated as blank, not as
    /// failures — a divider page should never cost an API call.
    public var blankPageCharacterFloor = 12

    public init(config: InkstoneConfig) {
        self.threshold = config.escalationThreshold
        self.enabled = config.cloudEscalationEnabled
    }

    public init(threshold: Double = 0.55, enabled: Bool = true) {
        self.threshold = threshold
        self.enabled = enabled
    }

    /// `inkCoverage` is the share of the page covered in ink, from the diagram
    /// pass. Pass nil when it has not been computed; the coverage signal is
    /// then skipped rather than guessed at.
    public func evaluate(_ transcript: PageTranscript, inkCoverage: Double? = nil) -> EscalationDecision {
        var reasons: [String] = []

        guard transcript.characterCount >= blankPageCharacterFloor else {
            return EscalationDecision(shouldEscalate: false, score: 1.0,
                                      reasons: ["page is blank or near-blank"])
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

        let score = 0.5 * confidence
            + 0.2 * (1 - weakFraction)
            + 0.15 * (1 - min(garbage / 0.4, 1))
            + 0.15 * coverageScore

        let shouldEscalate = enabled && (score < threshold || !reasons.isEmpty)
        if !enabled && !reasons.isEmpty {
            reasons.append("cloud escalation disabled — flagged for review instead")
        }
        return EscalationDecision(
            shouldEscalate: shouldEscalate,
            score: (score * 1000).rounded() / 1000,
            reasons: reasons)
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
