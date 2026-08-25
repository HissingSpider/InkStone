import CoreGraphics
import Foundation

public struct PipelineOptions: Sendable {
    /// Ignore cached hashes and re-transcribe everything.
    public var reprocessAll = false
    /// Rebuild every note from the page cache without re-transcribing.
    ///
    /// The document-level hash skip is what makes a steady-state run nearly
    /// free, but it assumes the notes it produced last time are still in the
    /// vault. They may not be — the vault moved, a note was deleted, or the
    /// granularity changed. This forces composition while keeping OCR and any
    /// API spend at zero.
    public var rewrite = false
    /// Overwrite notes even when they look hand-edited.
    public var force = false
    /// Report what would happen without touching the vault or the state store.
    public var dryRun = false
    /// Restrict the run to these PDFs. Empty means the whole inbox.
    public var only: [URL] = []
    public var granularity: NoteGranularity = .notebook

    public init() {}
}

public struct PipelineResult: Sendable {
    public var documentsScanned = 0
    public var documentsChanged = 0
    public var pagesProcessed = 0
    public var pagesEscalated = 0
    public var pagesCached = 0
    public var notesWritten = 0
    public var notesSkipped = 0
    public var diagramsExtracted = 0
    public var outcomes: [WriteOutcome] = []
    public var errors: [String] = []

    public var succeeded: Bool { errors.isEmpty }

    public var summaryLine: String {
        var parts = ["\(documentsChanged)/\(documentsScanned) notebooks changed",
                     "\(pagesProcessed) pages transcribed"]
        if pagesCached > 0 { parts.append("\(pagesCached) cached") }
        if pagesEscalated > 0 { parts.append("\(pagesEscalated) escalated") }
        if diagramsExtracted > 0 { parts.append("\(diagramsExtracted) diagrams") }
        parts.append("\(notesWritten) notes written")
        if notesSkipped > 0 { parts.append("\(notesSkipped) protected") }
        if !errors.isEmpty { parts.append("\(errors.count) errors") }
        return parts.joined(separator: ", ")
    }
}

/// The whole Inkstone run: inbox → PDF pages → OCR → markdown → vault.
///
/// Everything expensive is gated on a hash. A document whose bytes are unchanged
/// is skipped without opening it; a page whose bitmap is unchanged is served
/// from the state cache without OCR. In steady state a daily run over a shelf of
/// notebooks costs a few file hashes and nothing else.
public final class Pipeline: @unchecked Sendable {

    public let config: InkstoneConfig
    public let state: StateStore
    public var options: PipelineOptions

    private let ocr: VisionOCR
    private let gate: ConfidenceGate
    private let extractor: DiagramExtractor
    private let composer: NoteComposer
    private let vlm: (any VLMProvider)?

    public init(config: InkstoneConfig, state: StateStore, options: PipelineOptions = .init()) {
        self.config = config
        self.state = state
        self.options = options
        self.ocr = VisionOCR(config: config)
        self.gate = ConfidenceGate(config: config)
        self.extractor = DiagramExtractor(config: config)
        self.composer = NoteComposer(config: config, granularity: options.granularity)
        self.vlm = VLM.make(config: config)
    }

    // MARK: Run

    public func run() async -> PipelineResult {
        var result = PipelineResult()
        // A dry run leaves no trace at all, history included.
        let runID = options.dryRun ? nil : try? state.beginRun()

        do {
            let documents = try options.only.isEmpty
                ? Self.findPDFs(in: config.inboxURL)
                : options.only
            result.documentsScanned = documents.count

            guard !documents.isEmpty else {
                log.warn("no PDFs found under \(config.inboxURL.path)")
                finish(runID, result)
                return result
            }
            log.info("scanning \(documents.count) notebook(s) in \(config.inboxURL.path)")

            // Compose everything first, then write. Cross-linking needs the
            // full set of titles: a note produced from the first notebook has
            // to be able to link one produced from the last.
            var pending: [ComposedNote] = []
            for document in documents {
                do {
                    pending += try await process(document, into: &result)
                } catch {
                    let message = "\(document.lastPathComponent): \(error)"
                    log.error(message)
                    result.errors.append(message)
                }
            }
            try writeNotes(pending, into: &result)
        } catch {
            let message = "\(error)"
            log.error(message)
            result.errors.append(message)
        }

        log.info(result.summaryLine)
        finish(runID, result)
        return result
    }

    private func finish(_ runID: Int64?, _ result: PipelineResult) {
        guard let runID else { return }
        try? state.finishRun(
            id: runID,
            status: result.succeeded ? "ok" : "error",
            documentsScanned: result.documentsScanned,
            pagesProcessed: result.pagesProcessed,
            pagesEscalated: result.pagesEscalated,
            notesWritten: result.notesWritten,
            notesSkipped: result.notesSkipped,
            error: result.errors.first)
    }

    // MARK: One document

    /// Cross-links and writes the run's notes.
    private func writeNotes(_ notes: [ComposedNote], into result: inout PipelineResult) throws {
        var notes = notes

        if config.crossLink, !notes.isEmpty {
            // The user's own notes matter as much as ours — more, really. They
            // are the vault's existing vocabulary.
            var index = LinkIndex.scanningVault(at: config.vaultURL)
            for note in notes { index.add(note.title) }

            for offset in notes.indices {
                notes[offset].body = index.linkify(
                    notes[offset].body, excluding: notes[offset].title)
            }
        }

        guard !options.dryRun else {
            for note in notes {
                log.info("would write \(note.relativePath) (\(note.body.count) chars)")
                result.notesWritten += 1
            }
            return
        }

        let writer = VaultWriter(vaultURL: config.vaultURL, state: state, force: options.force)
        for note in notes {
            let outcome = try writer.write(note)
            result.outcomes.append(outcome)
            switch outcome {
            case .created(let url): log.info("created \(url.lastPathComponent)")
            case .updated(let url): log.info("updated \(url.lastPathComponent)")
            case .unchanged: break
            case .locked(let url, let sidecar):
                if sidecar == url {
                    log.info("locked and already merged: \(url.lastPathComponent)")
                } else {
                    log.info("locked, left alone: \(url.lastPathComponent) "
                             + "(new material in \(sidecar.lastPathComponent))")
                }
            case .protected(let note, let sidecar, let reason):
                log.warn("\(note.lastPathComponent) \(reason); wrote \(sidecar.lastPathComponent)")
            }
            if outcome.wroteNote { result.notesWritten += 1 }
            if case .protected = outcome { result.notesSkipped += 1 }
            if case .locked = outcome { result.notesSkipped += 1 }
        }
    }

    private func process(_ url: URL, into result: inout PipelineResult) async throws -> [ComposedNote] {
        // Canonicalise before it becomes a database key: the same PDF reached
        // through /var and /private/var, or through a symlinked vault, must not
        // grow two sets of page rows and re-OCR itself on every run.
        let path = url.resolvingSymlinksInPath().path
        let fileHash = try Hashing.sha256(fileAt: url)

        if !options.reprocessAll, !options.rewrite, try state.documentHash(path: path) == fileHash {
            log.debug("unchanged, skipping: \(url.lastPathComponent)")
            return []
        }
        result.documentsChanged += 1

        let renderer = try PDFPageRenderer(url: url)
        let notebook = renderer.documentTitle
        let slug = NoteComposer.slug(notebook)
        log.info("\(notebook): \(renderer.pageCount) page(s)")

        var pages: [PageOutput] = []

        for index in 0..<renderer.pageCount {
            let fingerprint = try renderer.fingerprint(pageIndex: index)

            if !options.reprocessAll,
               let cached = try state.pageRecord(documentPath: path, pageIndex: index),
               cached.imageHash == fingerprint {
                result.pagesCached += 1
                // Also checked on the way out of the cache, not just on the way
                // in, so a refusal already stored by an earlier version is
                // healed without paying to transcribe the page again.
                let markdown = VLMPrompt.looksLikeRefusal(cached.markdown) ? "" : cached.markdown
                pages.append(PageOutput(
                    pageIndex: index, markdown: markdown,
                    confidence: cached.confidence,
                    needsReview: cached.needsReview,
                    source: cached.escalated ? .vlm : .vision))

                // A cached page still embeds images. If those files went missing
                // — vault moved, attachments deleted — re-cut them from their
                // stored rectangles. Local work only; nothing is re-transcribed.
                if !options.dryRun, !cached.diagrams.isEmpty {
                    let restored = try restoreDiagrams(
                        cached.diagrams, renderer: renderer, pageIndex: index)
                    result.diagramsExtracted += restored
                }
                continue
            }

            let page = try await transcribe(
                renderer: renderer, pageIndex: index, notebook: notebook, slug: slug,
                result: &result)

            pages.append(PageOutput(
                pageIndex: index, markdown: page.markdown,
                confidence: page.quality, needsReview: page.needsReview,
                source: page.source))

            if !options.dryRun {
                try state.upsertPage(PageRecord(
                    documentPath: path, pageIndex: index, imageHash: fingerprint,
                    confidence: page.quality, escalated: page.source == .vlm,
                    needsReview: page.needsReview,
                    markdown: page.markdown, diagrams: page.diagrams, transcribedAt: Date()))
            }
        }

        let notes = composer.compose(notebook: notebook, sourceURL: url, pages: pages)

        if !options.dryRun {
            try state.trimPages(documentPath: path, to: renderer.pageCount)
            try state.recordDocument(path: path, baseName: notebook,
                                     fileHash: fileHash, pageCount: renderer.pageCount)
        }
        return notes
    }

    /// Repairs missing attachment files for an otherwise cached page.
    private func restoreDiagrams(
        _ crops: [DiagramCrop], renderer: PDFPageRenderer, pageIndex: Int
    ) throws -> Int {
        let anyMissing = crops.contains {
            !FileManager.default.fileExists(
                atPath: config.attachmentsURL.appendingPathComponent($0.fileName).path)
        }
        // The common case is that everything is present, and checking file
        // existence is far cheaper than rendering the page to find out.
        guard anyMissing else { return 0 }

        let rendered = try renderer.render(pageIndex: pageIndex, dpi: config.renderDPI)
        let restored = try extractor.restore(
            crops, from: rendered, attachmentsURL: config.attachmentsURL)
        if restored > 0 {
            log.info("restored \(restored) missing diagram(s) on page \(pageIndex + 1)")
        }
        return restored
    }

    // MARK: One page

    private struct TranscribedPage {
        var markdown: String
        /// The gate's blended score, not Vision's raw confidence.
        var quality: Double
        var needsReview: Bool
        var source: TranscriptSource
        var diagrams: [DiagramCrop]
    }

    private func transcribe(
        renderer: PDFPageRenderer, pageIndex: Int, notebook: String, slug: String,
        result: inout PipelineResult
    ) async throws -> TranscribedPage {
        let rendered = try renderer.render(pageIndex: pageIndex, dpi: config.renderDPI)
        var transcript = try ocr.transcribe(rendered)
        result.pagesProcessed += 1

        // Diagrams first: the confidence gate wants the ink-coverage number, and
        // the VLM prompt wants to know how many placeholders to emit.
        var inkCoverage: Double?
        if config.diagramExtractionEnabled {
            if options.dryRun {
                // Locate but do not crop: the gate still needs ink coverage, and
                // a dry run must not put PNGs in the user's attachments folder.
                let located = try extractor.locate(in: rendered, textBlocks: transcript.blocks)
                inkCoverage = located.inkCoverage
                result.diagramsExtracted += located.rects.count
            } else {
                let scan = try extractor.extract(
                    from: rendered, textBlocks: transcript.blocks,
                    slug: slug, attachmentsURL: config.attachmentsURL)
                transcript.diagrams = scan.crops
                inkCoverage = scan.inkCoverage
                result.diagramsExtracted += scan.crops.count
            }
        }

        let decision = gate.evaluate(transcript, inkCoverage: inkCoverage)
        if !decision.reasons.isEmpty {
            log.debug("page \(pageIndex + 1) score \(decision.score): "
                      + decision.reasons.joined(separator: "; "))
        }

        if decision.shouldEscalate, let vlm {
            do {
                let markdown = try await vlm.transcribe(
                    image: rendered.image, pageNumber: pageIndex + 1, notebook: notebook,
                    diagramCount: transcript.diagrams.count,
                    visionDraft: MarkdownBuilder().markdown(for: transcript.lines))
                guard !VLMPrompt.looksLikeRefusal(markdown) else {
                    // The model described the page instead of transcribing it,
                    // which means there was nothing on it. Record a blank page
                    // rather than writing its explanation into the vault.
                    log.info("page \(pageIndex + 1) came back blank from \(vlm.model)")
                    result.pagesEscalated += 1
                    return TranscribedPage(markdown: "", quality: 1.0, needsReview: false,
                                           source: .vlm, diagrams: transcript.diagrams)
                }
                result.pagesEscalated += 1
                log.info("page \(pageIndex + 1) escalated to \(vlm.model)")
                transcript.vlmMarkdown = markdown
                return TranscribedPage(
                    markdown: composer.pageBody(transcript),
                    // A VLM transcription is not scored by Vision; record it as
                    // fully confident so the page stops being re-escalated and
                    // stops dragging the note's mean down.
                    quality: 1.0, needsReview: false,
                    source: .vlm, diagrams: transcript.diagrams)
            } catch {
                // A failed escalation must not lose the local transcription.
                log.warn("page \(pageIndex + 1) escalation failed, keeping Vision output: \(error)")
                result.errors.append("page \(pageIndex + 1) escalation: \(error)")
            }
        }

        return TranscribedPage(
            markdown: composer.pageBody(transcript),
            quality: decision.score,
            needsReview: decision.needsReview,
            source: .vision, diagrams: transcript.diagrams)
    }

    // MARK: Inbox

    /// Confirms the inbox is genuinely readable, within a bounded time.
    ///
    /// Two failure modes make this necessary, and both are invisible without it.
    /// A launchd agent has no Full Disk Access by default, so a cloud-synced
    /// folder under ~/Library/CloudStorage returns "Operation not permitted" —
    /// and because that path is served by a File Provider extension, the call
    /// can block indefinitely rather than returning the error. A nightly run
    /// that hangs forever is worse than one that fails: it leaves no log, never
    /// completes, and quietly stops happening.
    public static func checkInboxAccess(_ url: URL, timeout: TimeInterval = 15) throws {
        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)` is sound here: the worker writes `failure`
        // exactly once before signalling, and nothing reads it until the wait
        // returns successfully.
        nonisolated(unsafe) var failure: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path) }
            catch { failure = error }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw InkstoneError.io("""
                timed out reading \(url.path).

                This usually means the process lacks Full Disk Access. Grant it in \
                System Settings → Privacy & Security → Full Disk Access — add \
                Inkstone.app, and your terminal if you run the CLI by hand.
                """)
        }
        if let failure = failure as NSError?,
           failure.domain == NSCocoaErrorDomain,
           failure.code == NSFileReadNoPermissionError || failure.code == 257 {
            throw InkstoneError.io("""
                not permitted to read \(url.path).

                Grant Full Disk Access in System Settings → Privacy & Security → \
                Full Disk Access, and add Inkstone.app. Scheduled runs get no \
                permission prompt of their own, so this has to be granted by hand.
                """)
        }
        if let failure { throw InkstoneError.io("cannot read \(url.path): \(failure)") }
    }

    /// Every PDF under `root`, sorted, ignoring hidden files and Google Drive's
    /// not-yet-downloaded placeholders (which are real files of near-zero size
    /// and would otherwise fail to open on every run).
    public static func findPDFs(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw InkstoneError.io("inbox does not exist: \(root.path)")
        }
        try checkInboxAccess(root)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw InkstoneError.io("cannot read \(root.path)") }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard (values?.fileSize ?? 0) > 1_024 else {
                log.warn("skipping placeholder or empty file: \(url.lastPathComponent)")
                continue
            }
            results.append(url.resolvingSymlinksInPath())
        }
        return results.sorted { $0.path < $1.path }
    }
}
