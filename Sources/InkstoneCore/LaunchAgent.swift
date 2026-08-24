import Foundation

/// Installs and removes the launchd agents that make Inkstone run unattended.
///
/// Two agents rather than one, because they answer different questions. The
/// daily agent guarantees a floor: notes appear even if the machine was asleep
/// when the backup landed. The watcher agent gives immediacy: a notebook synced
/// at lunchtime is transcribed minutes later. Running both is cheap — an
/// unchanged inbox costs a few file hashes.
public enum LaunchAgent {

    public static let dailyLabel = "com.inkstone.daily"
    public static let watchLabel = "com.inkstone.watch"

    public static var agentsDirectory: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/LaunchAgents").expandingTildeInPath)
    }

    public static func plistURL(label: String) -> URL {
        agentsDirectory.appendingPathComponent("\(label).plist")
    }

    // MARK: Install

    /// Writes and loads the daily agent, firing at `hour`:`minute` local time.
    public static func installDaily(
        executable: URL, hour: Int, minute: Int, configPath: String?
    ) throws -> URL {
        var arguments = [executable.path, "run"]
        if let configPath { arguments += ["--config", configPath] }

        return try install(label: dailyLabel, plist: plist(
            label: dailyLabel,
            arguments: arguments,
            extra: """
                    <key>StartCalendarInterval</key>
                    <dict>
                        <key>Hour</key><integer>\(hour)</integer>
                        <key>Minute</key><integer>\(minute)</integer>
                    </dict>
                    <key>RunAtLoad</key>
                    <false/>
                """))
    }

    /// Writes and loads the watcher agent, which stays resident.
    public static func installWatcher(executable: URL, configPath: String?) throws -> URL {
        var arguments = [executable.path, "watch"]
        if let configPath { arguments += ["--config", configPath] }

        return try install(label: watchLabel, plist: plist(
            label: watchLabel,
            arguments: arguments,
            extra: """
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <dict>
                        <key>SuccessfulExit</key>
                        <false/>
                    </dict>
                    <key>ThrottleInterval</key>
                    <integer>30</integer>
                """))
    }

    private static func install(label: String, plist: String) throws -> URL {
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let url = plistURL(label: label)
        try plist.write(to: url, atomically: true, encoding: .utf8)

        // Unload first so re-installing picks up a changed plist. `bootout`
        // fails harmlessly when nothing is loaded, hence the ignored status.
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = try runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        guard result.status == 0 else {
            throw InkstoneError.io("launchctl bootstrap failed: \(result.output)")
        }
        return url
    }

    // MARK: Remove

    @discardableResult
    public static func uninstall(label: String) throws -> Bool {
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        let url = plistURL(label: label)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    public static func isInstalled(label: String) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(label: label).path)
    }

    public static func isLoaded(label: String) -> Bool {
        guard let result = try? runLaunchctl(["print", "gui/\(getuid())/\(label)"]) else {
            return false
        }
        return result.status == 0
    }

    /// True when launchd recorded a zero exit for this agent's last run.
    ///
    /// This is the only cheap way to know whether a scheduled job actually
    /// worked, as opposed to whether it is installed. A terminal cannot observe
    /// an agent's permissions directly — it has its own, usually broader ones.
    public static func lastExitWasClean(label: String) -> Bool {
        guard let result = try? runLaunchctl(["print", "gui/\(getuid())/\(label)"]),
              result.status == 0
        else { return false }

        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("last exit code = ") else { continue }
            return trimmed.hasSuffix("= 0")
        }
        return false
    }

    // MARK: Plist

    static func plist(label: String, arguments: [String], extra: String) -> String {
        let argumentXML = arguments
            .map { "        <string>\(escape($0))</string>" }
            .joined(separator: "\n")
        let logPath = Logger.defaultLogURL.deletingLastPathComponent()
            .appendingPathComponent("\(label).log").path

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
            \(argumentXML)
                </array>
            \(extra)
                <key>StandardOutPath</key>
                <string>\(escape(logPath))</string>
                <key>StandardErrorPath</key>
                <string>\(escape(logPath))</string>
                <key>ProcessType</key>
                <string>Background</string>
                <key>LowPriorityIO</key>
                <true/>
                <key>EnvironmentVariables</key>
                <dict>
                    <key>PATH</key>
                    <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
                </dict>
            </dict>
            </plist>
            """
    }

    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
