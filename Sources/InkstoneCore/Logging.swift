import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info "
        case .warn: return "warn "
        case .error: return "error"
        }
    }
}

/// Line-oriented logger writing to stderr and, optionally, a rotating file.
///
/// stderr is deliberate: the CLI's stdout stays clean so `inkstone status --json`
/// can be piped into `jq` while the log still reaches the terminal.
public final class Logger: @unchecked Sendable {

    public static let shared = Logger()

    public var level: LogLevel = .info
    private var fileHandle: FileHandle?
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init() {}

    /// Default log location, used by the launchd agent and the menu-bar app.
    public static var defaultLogURL: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/Logs/Inkstone/inkstone.log")
            .expandingTildeInPath)
    }

    public func attachFile(at url: URL = Logger.defaultLogURL, maxBytes: Int = 2_000_000) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Rotate once, keeping a single `.1` generation. Two files of bounded
        // size is plenty for a tool that runs a handful of times a day.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }

        lock.lock(); defer { lock.unlock() }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public func log(_ level: LogLevel, _ message: String) {
        guard level >= self.level else { return }
        let line = "[\(formatter.string(from: Date()))] \(level.label) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        if let fh = fileHandle {
            try? fh.write(contentsOf: Data(line.utf8))
        }
    }

    public func debug(_ m: String) { log(.debug, m) }
    public func info(_ m: String) { log(.info, m) }
    public func warn(_ m: String) { log(.warn, m) }
    public func error(_ m: String) { log(.error, m) }
}

public let log = Logger.shared
