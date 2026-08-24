import Foundation

/// Where an API key comes from, and why that matters for unattended runs.
///
/// The environment is the obvious source and the wrong one to rely on alone.
/// `~/.zshrc` is read only by interactive shells, and launchd never sources a
/// shell profile at all, so a key that works perfectly in a terminal is simply
/// absent from the nightly agent. `launchctl setenv` bridges the gap until the
/// next reboot and then quietly stops. The failure is invisible: escalation
/// switches itself off, pages get transcribed by local OCR and flagged for
/// review, and nothing reports an error.
///
/// A file both sides can read is the fix. One place to look, one place to
/// rotate, and it survives a restart.
public enum Credentials {

    /// `~/.config/inkstone/credentials`
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.config/inkstone/credentials")
            .expandingTildeInPath)
    }

    public struct Resolution: Sendable {
        public var value: String?
        /// Human-readable origin, for `doctor` to report.
        public var source: String
        /// Set when the file exists but anyone other than the owner can read it.
        public var permissionWarning: String?
    }

    /// Looks for `variable` in the environment first, then in the credentials
    /// file. The environment wins so a one-off override still works:
    /// `OPENAI_API_KEY=sk-other inkstone run`.
    public static func resolve(
        variable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) -> Resolution {
        if let value = environment[variable], !value.isEmpty {
            return Resolution(value: value, source: "environment", permissionWarning: nil)
        }

        let url = fileURL ?? defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Resolution(value: nil, source: "not found", permissionWarning: nil)
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return Resolution(value: nil, source: "unreadable \(url.path)", permissionWarning: nil)
        }

        var warning: String?
        if let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber, mode.int16Value & 0o077 != 0 {
            warning = String(format: "%@ is mode %03o; it should be 600",
                             url.path, mode.int16Value)
        }

        let value = parse(contents)[variable]
        return Resolution(
            value: value,
            source: value == nil ? "absent from \(url.path)" : url.path,
            permissionWarning: value == nil ? nil : warning)
    }

    /// Parses `KEY=value` lines, with or without `export` and quotes.
    ///
    /// The format is deliberately shell-compatible: the same file can be
    /// `source`d from `.zshrc`, so the key is defined once and both the
    /// interactive shell and the launchd agent get it from the same place.
    public static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let name = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            // Strip one matched pair of quotes, not every quote: a key never
            // contains them, but mangling the value silently would be worse
            // than leaving it alone.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty, !value.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// Writes or replaces `variable` in the credentials file, creating it with
    /// owner-only permissions and preserving any other variables already there.
    public static func store(_ value: String, as variable: String, at url: URL? = nil) throws {
        let url = url ?? defaultURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var values = parse(existing)
        values[variable] = value

        let body = """
            # Inkstone credentials. Owner-readable only.
            #
            # Shell-compatible on purpose — add this to your ~/.zshrc so the key is
            # defined in exactly one place:
            #
            #     source ~/.config/inkstone/credentials
            #
            """ + "\n"
            + values.keys.sorted().map { "export \($0)=\"\(values[$0]!)\"" }.joined(separator: "\n")
            + "\n"

        // Create with 0600 from the start rather than writing then chmod-ing;
        // otherwise the key is briefly world-readable on disk.
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data(body.utf8),
                            attributes: [.posixPermissions: 0o600])
        else { throw InkstoneError.io("cannot write \(url.path)") }
    }
}
