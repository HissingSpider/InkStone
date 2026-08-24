import CoreGraphics
import Foundation
import Testing
@testable import InkstoneCore

/// Full-pipeline tests against real PDFs, real PDFKit rendering and real Vision
/// recognition — no stubs below the API boundary. They are the only place that
/// proves the pieces actually fit together.
@Suite("End to end", .serialized)
struct EndToEndTests {

    /// Builds an inbox, a vault and a state store in a scratch directory.
    private func withWorkspace(
        _ body: (InkstoneConfig, StateStore, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-e2e-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox")
        let vault = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = InkstoneConfig.default
        config.inboxPath = inbox.path
        config.vaultPath = vault.path
        config.notesSubfolder = "Inkstone"
        config.attachmentsSubfolder = "Inkstone/attachments"
        config.renderDPI = 200
        config.cloudEscalationEnabled = false

        let state = try StateStore(url: root.appendingPathComponent("state.sqlite3"))
        try await body(config, state, inbox)
    }

    @Test("A notebook becomes a note with frontmatter and recognisable text")
    func transcribesANotebook() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(
                at: inbox.appendingPathComponent("Field Notes.pdf"),
                title: "Field Notes",
                pages: [
                    .init(lines: ["#Observations", "Tide was low at dawn",
                                  "- gulls on the sandbar", "- three seals"]),
                    .init(lines: ["Weather turned by noon"]),
                ])

            let result = await Pipeline(config: config, state: state).run()
            #expect(result.errors.isEmpty, "\(result.errors)")
            #expect(result.documentsChanged == 1)
            #expect(result.pagesProcessed == 2)
            #expect(result.notesWritten == 1)

            let note = config.notesURL.appendingPathComponent("Field Notes.md")
            let contents = try String(contentsOf: note, encoding: .utf8)

            #expect(contents.hasPrefix("---\n"))
            #expect(contents.contains("notebook: Field Notes"))
            #expect(contents.contains("tags: [inkstone, handwritten]"))
            // Provenance lives in a footer, not in the properties block.
            #expect(contents.contains("> [!abstract]- Transcription"))
            #expect(contents.contains("`Field Notes.pdf`"))
            // Vision on rendered Helvetica is reliable enough to assert on the
            // actual words; if this ever breaks, recognition genuinely broke.
            #expect(contents.contains("sandbar"), "\(contents)")
            #expect(contents.contains("Weather"), "\(contents)")
        }
    }

    @Test("An unchanged notebook is skipped, and its pages are served from cache")
    func secondRunIsCheap() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(at: inbox.appendingPathComponent("Log.pdf"), title: "Log",
                                 pages: [.init(lines: ["First entry", "Second entry"])])

            let first = await Pipeline(config: config, state: state).run()
            #expect(first.pagesProcessed == 1)

            let second = await Pipeline(config: config, state: state).run()
            #expect(second.documentsChanged == 0)
            #expect(second.pagesProcessed == 0)
            #expect(second.notesWritten == 0)
        }
    }

    @Test("Adding a page re-transcribes only that page")
    func changeDetectionIsPerPage() async throws {
        try await withWorkspace { config, state, inbox in
            let url = inbox.appendingPathComponent("Journal.pdf")
            try Fixtures.makePDF(at: url, title: "Journal",
                                 pages: [.init(lines: ["Monday was quiet"]),
                                         .init(lines: ["Tuesday it rained"])])
            _ = await Pipeline(config: config, state: state).run()

            // Same two pages, plus a third. The file hash changes, so the
            // document is reopened, but pages one and two must come from cache.
            try Fixtures.makePDF(at: url, title: "Journal",
                                 pages: [.init(lines: ["Monday was quiet"]),
                                         .init(lines: ["Tuesday it rained"]),
                                         .init(lines: ["Wednesday the sun came back"])])

            let second = await Pipeline(config: config, state: state).run()
            #expect(second.documentsChanged == 1)
            #expect(second.pagesCached == 2)
            #expect(second.pagesProcessed == 1)

            let contents = try String(
                contentsOf: config.notesURL.appendingPathComponent("Journal.md"), encoding: .utf8)
            #expect(contents.contains("Wednesday"), "\(contents)")
        }
    }

    @Test("A hand-edited note is never overwritten; the new transcription goes to a sidecar")
    func handEditsAreProtected() async throws {
        try await withWorkspace { config, state, inbox in
            let url = inbox.appendingPathComponent("Ideas.pdf")
            try Fixtures.makePDF(at: url, title: "Ideas",
                                 pages: [.init(lines: ["The first idea"])])
            _ = await Pipeline(config: config, state: state).run()

            let note = config.notesURL.appendingPathComponent("Ideas.md")
            let mine = try String(contentsOf: note, encoding: .utf8)
                + "\n\nMy own thoughts, which must survive.\n"
            try mine.write(to: note, atomically: true, encoding: .utf8)

            // A changed source forces a rewrite attempt.
            try Fixtures.makePDF(at: url, title: "Ideas",
                                 pages: [.init(lines: ["The first idea"]),
                                         .init(lines: ["A second idea"])])
            let result = await Pipeline(config: config, state: state).run()

            #expect(result.notesSkipped == 1)
            #expect(result.notesWritten == 0)
            #expect(try String(contentsOf: note, encoding: .utf8) == mine)

            let sidecar = config.notesURL.appendingPathComponent("Ideas.inkstone-new.md")
            #expect(FileManager.default.fileExists(atPath: sidecar.path))
            // The sidecar holds the full new transcription, both pages of it.
            let rejected = try String(contentsOf: sidecar, encoding: .utf8)
            #expect(rejected.contains("second idea") || rejected.contains("A second"),
                    "\(rejected)")
        }
    }

    @Test("inkstone_lock: true keeps a note untouched even with --force")
    func lockedNotesAreLeftAlone() async throws {
        try await withWorkspace { config, state, inbox in
            let note = config.notesURL.appendingPathComponent("Pinned.md")
            try FileManager.default.createDirectory(
                at: config.notesURL, withIntermediateDirectories: true)
            let locked = "---\ntitle: Pinned\ninkstone_lock: true\n---\n\nhands off\n"
            try locked.write(to: note, atomically: true, encoding: .utf8)

            try Fixtures.makePDF(at: inbox.appendingPathComponent("Pinned.pdf"), title: "Pinned",
                                 pages: [.init(lines: ["New content here"])])

            var options = PipelineOptions()
            options.force = true
            let result = await Pipeline(config: config, state: state, options: options).run()

            #expect(result.notesSkipped == 1)
            #expect(try String(contentsOf: note, encoding: .utf8) == locked)
        }
    }

    @Test("--dry-run writes nothing at all")
    func dryRunTouchesNothing() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(at: inbox.appendingPathComponent("Draft.pdf"), title: "Draft",
                                 pages: [.init(lines: ["Something to transcribe"])])

            var options = PipelineOptions()
            options.dryRun = true
            _ = await Pipeline(config: config, state: state, options: options).run()

            #expect(!FileManager.default.fileExists(
                atPath: config.notesURL.appendingPathComponent("Draft.md").path))
            // And nothing was cached, so a real run afterwards still does the work.
            let real = await Pipeline(config: config, state: state).run()
            #expect(real.pagesProcessed == 1)
        }
    }

    @Test("A drawing is cropped to attachments and embedded where it sits on the page")
    func diagramsAreExtractedAndEmbedded() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(
                at: inbox.appendingPathComponent("Sketches.pdf"), title: "Sketches",
                pages: [.init(lines: ["Circuit for the doorbell"], includeDiagram: true)])

            let result = await Pipeline(config: config, state: state).run()
            #expect(result.diagramsExtracted >= 1, "no diagram found")

            let attachments = try FileManager.default.contentsOfDirectory(
                atPath: config.attachmentsURL.path)
            #expect(attachments.contains { $0.hasPrefix("sketches-p1-") && $0.hasSuffix(".png") },
                    "\(attachments)")

            let contents = try String(
                contentsOf: config.notesURL.appendingPathComponent("Sketches.md"), encoding: .utf8)
            #expect(contents.contains("![[sketches-p1-1.png]]"), "\(contents)")
            // The text is above the drawing on the page, so it must come first.
            let textIndex = try #require(contents.range(of: "doorbell")).lowerBound
            let embedIndex = try #require(contents.range(of: "![[sketches-p1-")).lowerBound
            #expect(textIndex < embedIndex)
        }
    }

    @Test("A page of text alone yields no spurious diagrams")
    func textOnlyPagesProduceNoDiagrams() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(
                at: inbox.appendingPathComponent("Prose.pdf"), title: "Prose",
                pages: [.init(lines: ["A page of nothing but writing",
                                      "with several ordinary lines",
                                      "and no drawing anywhere on it"])])

            let result = await Pipeline(config: config, state: state).run()
            #expect(result.diagramsExtracted == 0)
        }
    }

    @Test("Routing puts a notebook in its configured folder")
    func routingIsHonoured() async throws {
        try await withWorkspace { config, state, inbox in
            var config = config
            config.notebookRouting = ["Physics": "Courses/Physics"]
            try Fixtures.makePDF(at: inbox.appendingPathComponent("Physics.pdf"), title: "Physics",
                                 pages: [.init(lines: ["Newtons second law"])])

            _ = await Pipeline(config: config, state: state).run()
            #expect(FileManager.default.fileExists(atPath: config.vaultURL
                .appendingPathComponent("Courses/Physics/Physics.md").path))
        }
    }

    @Test("A corrupt PDF fails that notebook alone and the run continues")
    func oneBadFileDoesNotStopTheRun() async throws {
        try await withWorkspace { config, state, inbox in
            try Data(repeating: 0x41, count: 4_096)
                .write(to: inbox.appendingPathComponent("Broken.pdf"))
            try Fixtures.makePDF(at: inbox.appendingPathComponent("Good.pdf"), title: "Good",
                                 pages: [.init(lines: ["This one is fine"])])

            let result = await Pipeline(config: config, state: state).run()
            #expect(result.errors.count == 1)
            #expect(result.notesWritten == 1)
            #expect(FileManager.default.fileExists(
                atPath: config.notesURL.appendingPathComponent("Good.md").path))
        }
    }

    @Test("Run history is recorded for the status command and the menu bar")
    func runsAreRecorded() async throws {
        try await withWorkspace { config, state, inbox in
            try Fixtures.makePDF(at: inbox.appendingPathComponent("A.pdf"), title: "A",
                                 pages: [.init(lines: ["Some words"])])
            _ = await Pipeline(config: config, state: state).run()

            let runs = try state.recentRuns(limit: 5)
            let latest = try #require(runs.first)
            #expect(latest.status == "ok")
            #expect(latest.finishedAt != nil)
            #expect(latest.pagesProcessed == 1)
            #expect(latest.notesWritten == 1)
        }
    }

    @Test("A shrunken notebook drops its stale page rows")
    func removedPagesAreTrimmed() async throws {
        try await withWorkspace { config, state, inbox in
            let url = inbox.appendingPathComponent("Trim.pdf")
            try Fixtures.makePDF(at: url, title: "Trim",
                                 pages: [.init(lines: ["Page one text"]),
                                         .init(lines: ["Page two text"])])
            _ = await Pipeline(config: config, state: state).run()
            let key = url.resolvingSymlinksInPath().path
            #expect(try state.pageRecord(documentPath: key, pageIndex: 1) != nil)

            try Fixtures.makePDF(at: url, title: "Trim", pages: [.init(lines: ["Page one text"])])
            _ = await Pipeline(config: config, state: state).run()
            #expect(try state.pageRecord(documentPath: key, pageIndex: 1) == nil)
        }
    }
}

@Suite("Rendering and hashing")
struct RenderingTests {

    @Test("A page fingerprint is stable across runs and changes when the ink does")
    func fingerprintsTrackContent() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let a = directory.appendingPathComponent("a.pdf")
            let b = directory.appendingPathComponent("b.pdf")
            try Fixtures.makePDF(at: a, title: "A", pages: [.init(lines: ["hello world"])])
            try Fixtures.makePDF(at: b, title: "B", pages: [.init(lines: ["hello world!"])])

            let first = try PDFPageRenderer(url: a).fingerprint(pageIndex: 0)
            let again = try PDFPageRenderer(url: a).fingerprint(pageIndex: 0)
            let other = try PDFPageRenderer(url: b).fingerprint(pageIndex: 0)

            #expect(first == again)
            #expect(first != other)
        }
    }

    @Test("Render size follows the requested DPI")
    func renderHonoursDPI() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("p.pdf")
            try Fixtures.makePDF(at: url, title: "P", pages: [.init(lines: ["x"])])
            let renderer = try PDFPageRenderer(url: url)

            let low = try renderer.render(pageIndex: 0, dpi: 72)
            let high = try renderer.render(pageIndex: 0, dpi: 144)
            #expect(low.pixelWidth == Int(Fixtures.pageSize.width))
            #expect(high.pixelWidth == low.pixelWidth * 2)
        }
    }

    @Test("The document title comes from PDF metadata, not the file name")
    func titleComesFromMetadata() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("export-2026.pdf")
            try Fixtures.makePDF(at: url, title: "Lab Notebook", pages: [.init(lines: ["x"])])
            #expect(try PDFPageRenderer(url: url).documentTitle == "Lab Notebook")
        }
    }

    @Test("Opening a file that is not a PDF throws rather than crashing")
    func badFileThrows() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("not.pdf")
            try Data("nonsense".utf8).write(to: url)
            #expect(throws: (any Error).self) { try PDFPageRenderer(url: url) }
        }
    }

    @Test("Vision reads rendered text off a real page")
    func visionRecognisesRenderedText() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("v.pdf")
            try Fixtures.makePDF(at: url, title: "V",
                                 pages: [.init(lines: ["Migration notes", "Departure in autumn"])])
            let page = try PDFPageRenderer(url: url).render(pageIndex: 0, dpi: 200)
            let transcript = try VisionOCR().transcribe(page)

            #expect(transcript.lines.count >= 2)
            #expect(transcript.confidence > 0.5)
            let text = transcript.lines.map(\.text).joined(separator: " ")
            #expect(text.contains("Migration"), "\(text)")
            #expect(text.contains("autumn"), "\(text)")
        }
    }
}

@Suite("State store")
struct StateStoreTests {

    private func withStore(_ body: (StateStore) throws -> Void) throws {
        try Fixtures.withTemporaryDirectory { directory in
            try body(try StateStore(url: directory.appendingPathComponent("state.sqlite3")))
        }
    }

    @Test func pageRecordsRoundTripIncludingDiagrams() throws {
        try withStore { state in
            let record = PageRecord(
                documentPath: "/tmp/a.pdf", pageIndex: 2, imageHash: "abc",
                confidence: 0.81, escalated: true, markdown: "# Hi\n\n![[d.png]]",
                diagrams: [DiagramCrop(pageIndex: 2, index: 0,
                                       pixelRect: CGRect(x: 1, y: 2, width: 3, height: 4),
                                       anchorTopDownY: 0.5, fileName: "d.png")],
                transcribedAt: Date())
            try state.upsertPage(record)

            let loaded = try #require(try state.pageRecord(documentPath: "/tmp/a.pdf", pageIndex: 2))
            #expect(loaded.imageHash == "abc")
            #expect(loaded.escalated)
            #expect(loaded.markdown == "# Hi\n\n![[d.png]]")
            #expect(loaded.diagrams.first?.fileName == "d.png")
            #expect(loaded.diagrams.first?.pixelRect.width == 3)
        }
    }

    @Test func upsertReplacesRatherThanDuplicating() throws {
        try withStore { state in
            for hash in ["one", "two"] {
                try state.upsertPage(PageRecord(
                    documentPath: "/x.pdf", pageIndex: 0, imageHash: hash, confidence: 1,
                    escalated: false, markdown: hash, diagrams: [], transcribedAt: Date()))
            }
            #expect(try state.pageRecord(documentPath: "/x.pdf", pageIndex: 0)?.imageHash == "two")
        }
    }

    @Test func runsAreOrderedNewestFirst() throws {
        try withStore { state in
            for _ in 0..<3 {
                let id = try state.beginRun()
                try state.finishRun(id: id, status: "ok", documentsScanned: 1, pagesProcessed: 1,
                                    pagesEscalated: 0, notesWritten: 1, notesSkipped: 0, error: nil)
            }
            let runs = try state.recentRuns(limit: 10)
            #expect(runs.count == 3)
            #expect(runs[0].id > runs[1].id)
        }
    }

    @Test func resetClearsCachesButKeepsHistory() throws {
        try withStore { state in
            let id = try state.beginRun()
            try state.finishRun(id: id, status: "ok", documentsScanned: 1, pagesProcessed: 1,
                                pagesEscalated: 0, notesWritten: 1, notesSkipped: 0, error: nil)
            try state.upsertPage(PageRecord(
                documentPath: "/x.pdf", pageIndex: 0, imageHash: "h", confidence: 1,
                escalated: false, markdown: "m", diagrams: [], transcribedAt: Date()))

            try state.resetTranscriptionState()
            #expect(try state.pageRecord(documentPath: "/x.pdf", pageIndex: 0) == nil)
            #expect(try state.recentRuns(limit: 10).count == 1)
        }
    }
}

@Suite("Dry run leaves no trace", .serialized)
struct DryRunTests {

    @Test("A dry run writes no diagram PNGs and records no run history")
    func dryRunIsInert() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-dry-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = InkstoneConfig.default
        config.inboxPath = inbox.path
        config.vaultPath = root.appendingPathComponent("Vault").path
        config.renderDPI = 150
        config.cloudEscalationEnabled = false

        try Fixtures.makePDF(at: inbox.appendingPathComponent("Sketch.pdf"), title: "Sketch",
                             pages: [.init(lines: ["A labelled drawing"], includeDiagram: true)])

        let state = try StateStore(url: root.appendingPathComponent("state.sqlite3"))
        var options = PipelineOptions()
        options.dryRun = true
        let result = await Pipeline(config: config, state: state, options: options).run()

        #expect(result.diagramsExtracted >= 1, "the diagram should still be reported")
        #expect(!FileManager.default.fileExists(atPath: config.attachmentsURL.path),
                "dry run must not create the attachments folder")
        #expect(try state.recentRuns(limit: 10).isEmpty,
                "dry run must not appear in run history")
    }
}

@Suite("Rewrite from cache", .serialized)
struct RewriteTests {

    @Test("--rewrite rebuilds a deleted note without re-transcribing it")
    func rewritesWithoutReprocessing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-rewrite-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = InkstoneConfig.default
        config.inboxPath = inbox.path
        config.vaultPath = root.appendingPathComponent("Vault").path
        config.renderDPI = 150

        try Fixtures.makePDF(at: inbox.appendingPathComponent("Log.pdf"), title: "Log",
                             pages: [.init(lines: ["First entry here"])])
        let state = try StateStore(url: root.appendingPathComponent("state.sqlite3"))

        let first = await Pipeline(config: config, state: state).run()
        #expect(first.pagesProcessed == 1)

        // Simulate the note going missing — vault moved, file deleted, whatever.
        let note = config.notesURL.appendingPathComponent("Log.md")
        try FileManager.default.removeItem(at: note)

        // A normal run skips the whole document on its unchanged file hash, so
        // the missing note stays missing.
        let skipped = await Pipeline(config: config, state: state).run()
        #expect(skipped.notesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: note.path))

        var options = PipelineOptions()
        options.rewrite = true
        let rebuilt = await Pipeline(config: config, state: state, options: options).run()

        #expect(rebuilt.notesWritten == 1)
        // The point of the flag: nothing was re-transcribed, so nothing was paid for.
        #expect(rebuilt.pagesProcessed == 0)
        #expect(rebuilt.pagesCached == 1)
        #expect(FileManager.default.fileExists(atPath: note.path))
    }
}

@Suite("Attachment repair", .serialized)
struct AttachmentRepairTests {

    @Test("Deleted diagram files are re-cut from cache, without re-transcribing")
    func restoresMissingAttachments() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-repair-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = InkstoneConfig.default
        config.inboxPath = inbox.path
        config.vaultPath = root.appendingPathComponent("Vault").path
        config.renderDPI = 150

        try Fixtures.makePDF(at: inbox.appendingPathComponent("Sketch.pdf"), title: "Sketch",
                             pages: [.init(lines: ["A labelled drawing"], includeDiagram: true)])
        let state = try StateStore(url: root.appendingPathComponent("state.sqlite3"))

        let first = await Pipeline(config: config, state: state).run()
        #expect(first.diagramsExtracted >= 1)

        let attachments = config.attachmentsURL
        let before = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        #expect(!before.isEmpty)

        // Someone deletes the attachments folder. The notes still reference it.
        try FileManager.default.removeItem(at: attachments)

        var options = PipelineOptions()
        options.rewrite = true
        let repaired = await Pipeline(config: config, state: state, options: options).run()

        // Nothing re-transcribed, so nothing was paid for — but the files are back.
        #expect(repaired.pagesProcessed == 0)
        #expect(repaired.pagesCached == 1)
        #expect(repaired.diagramsExtracted == before.count)

        let after = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        #expect(Set(after) == Set(before))
    }
}

@Suite("Frontmatter does not accrete", .serialized)
struct FrontmatterAccretionTests {

    @Test("A dropped property stays dropped across rewrites")
    func removedKeysDoNotComeBack() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-accrete-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = InkstoneConfig.default
        config.inboxPath = inbox.path
        config.vaultPath = root.appendingPathComponent("Vault").path
        config.renderDPI = 150

        try Fixtures.makePDF(at: inbox.appendingPathComponent("Log.pdf"), title: "Log",
                             pages: [.init(lines: ["Some content here"])])
        let state = try StateStore(url: root.appendingPathComponent("state.sqlite3"))
        _ = await Pipeline(config: config, state: state).run()

        let note = config.notesURL.appendingPathComponent("Log.md")
        // Pretend an older version wrote a `created` property.
        var contents = try String(contentsOf: note, encoding: .utf8)
        contents = contents.replacingOccurrences(
            of: "---\n", with: "---\ncreated: 2020-01-01\n", options: [], range:
                contents.range(of: "---\n"))
        try contents.write(to: note, atomically: true, encoding: .utf8)

        var options = PipelineOptions()
        options.rewrite = true
        options.force = true
        _ = await Pipeline(config: config, state: state, options: options).run()

        let rewritten = try String(contentsOf: note, encoding: .utf8)
        #expect(!rewritten.contains("created:"), "\(rewritten)")
    }
}
