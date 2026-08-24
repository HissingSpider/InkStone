import Foundation

/// A tiny positional-and-flag parser.
///
/// Hand-rolled on purpose: pulling ArgumentParser in would make `swift build`
/// require a network fetch, and Inkstone's whole point is running unattended on
/// one machine with no moving parts.
struct Arguments {
    let command: String
    private var flags: Set<String> = []
    private var values: [String: [String]] = [:]

    init(_ argv: [String]) {
        var rest = argv
        command = rest.first.map { $0.hasPrefix("-") ? "" : $0 } ?? ""
        if !command.isEmpty { rest.removeFirst() }

        var index = 0
        while index < rest.count {
            let token = rest[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let key = String(token.dropFirst(2))
            let next = index + 1 < rest.count ? rest[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                values[key, default: []].append(next)
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
    func value(_ name: String) -> String? { values[name]?.first }
    func list(_ name: String) -> [String] { values[name] ?? [] }

    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
}
