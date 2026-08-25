import Foundation

/// Approximate string matching for names that came out of a recogniser.
///
/// A heading the recogniser can barely read is read *differently* each time. One
/// run produced "Vector upending", the next "Vector uperting"; one gave
/// "Anna Only", the next "Annual only". Anything keyed on the exact text — an
/// alias, a routing rule — therefore works once and then silently stops,
/// stranding the note under a new name and breaking every link into it.
///
/// Matching by edit distance instead makes a correction stick across runs.
public enum FuzzyMatch {

    /// Levenshtein distance, computed with two rows rather than a full matrix
    /// because only the previous row is ever needed.
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// True when `a` and `b` are the same name read twice by an unreliable eye.
    ///
    /// The tolerance scales with length: a quarter of the characters may differ,
    /// which catches the observed misreadings without letting genuinely
    /// different short titles collapse into one another.
    public static func matches(_ a: String, _ b: String, tolerance: Double = 0.25) -> Bool {
        let a = normalise(a), b = normalise(b)
        if a == b { return true }
        // Below five characters, a quarter of the string is one letter, and one
        // letter is the difference between "add" and "odd".
        guard max(a.count, b.count) >= 5 else { return false }

        let allowed = max(1, Int((Double(max(a.count, b.count)) * tolerance).rounded()))
        return distance(a, b) <= allowed
    }

    /// Lowercased, whitespace-collapsed, punctuation-stripped.
    static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
