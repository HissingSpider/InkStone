import Foundation

enum Output {

    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func print(_ text: String = "") {
        Swift.print(text)
    }

    static func style(_ text: String, _ code: String) -> String {
        isTTY ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func bold(_ text: String) -> String { style(text, "1") }
    static func dim(_ text: String) -> String { style(text, "2") }
    static func green(_ text: String) -> String { style(text, "32") }
    static func yellow(_ text: String) -> String { style(text, "33") }
    static func red(_ text: String) -> String { style(text, "31") }

    /// Collapses a multi-line message onto one line.
    ///
    /// Errors carry paragraph-length remedies, which read well in a log file and
    /// wreck a column-aligned terminal report.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func json(_ object: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        Swift.print(text)
    }
}
