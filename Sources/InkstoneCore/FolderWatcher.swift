import CoreServices
import Foundation

/// Watches the inbox for changes and fires after the dust settles.
///
/// Debouncing is not a nicety here. Google Drive writes a synced PDF in pieces
/// and renames it into place, so a single backup produces a burst of events over
/// several seconds; running the pipeline on the first one would read a truncated
/// file. The watcher therefore waits for a quiet period with no further events
/// before calling back.
public final class FolderWatcher: @unchecked Sendable {

    public typealias Handler = @Sendable ([URL]) -> Void

    private let paths: [URL]
    private let quietPeriod: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.inkstone.watcher")

    private var stream: FSEventStreamRef?
    private var pending: Set<URL> = []
    private var debounce: DispatchWorkItem?

    public init(paths: [URL], quietPeriod: TimeInterval = 20, handler: @escaping Handler) {
        self.paths = paths
        self.quietPeriod = quietPeriod
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            watcher.received(Array(paths.prefix(count)))
        }

        // `kFSEventStreamCreateFlagFileEvents` gives per-file paths rather than
        // directory-level notifications, which is what lets us filter to PDFs
        // and hand the pipeline an exact work list.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, flags)
        else { throw InkstoneError.io("cannot watch \(paths.map(\.path).joined(separator: ", "))") }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        log.info("watching \(paths.map(\.path).joined(separator: ", ")) "
                 + "(settling for \(Int(quietPeriod))s after each change)")
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounce?.cancel()
    }

    private func received(_ paths: [String]) {
        let pdfs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !pdfs.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.pending.formUnion(pdfs)
            self.debounce?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Only hand on files that still exist and are readable; a
                // rename burst leaves temporary names behind.
                let batch = self.pending.filter {
                    FileManager.default.isReadableFile(atPath: $0.path)
                }
                self.pending.removeAll()
                guard !batch.isEmpty else { return }
                log.info("change settled: \(batch.count) file(s)")
                self.handler(batch.sorted { $0.path < $1.path })
            }
            self.debounce = work
            self.queue.asyncAfter(deadline: .now() + self.quietPeriod, execute: work)
        }
    }
}
