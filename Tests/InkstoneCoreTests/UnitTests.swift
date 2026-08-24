import CoreGraphics
import Foundation
import Testing
@testable import InkstoneCore

@Suite("Config")
struct ConfigTests {

    @Test("A partial config file inherits defaults for every key it omits")
    func partialConfigInheritsDefaults() throws {
        let json = Data(##"{"vaultPath": "/tmp/vault", "renderDPI": 150}"##.utf8)
        let config = try InkstoneConfig.merging(defaults: .default, with: json)

        #expect(config.vaultPath == "/tmp/vault")
        #expect(config.renderDPI == 150)
        // This is what lets a config written by an older version keep working
        // when a new field is added.
        #expect(config.escalationThreshold == InkstoneConfig.default.escalationThreshold)
        #expect(config.defaultTags == InkstoneConfig.default.defaultTags)
    }

    @Test func roundTripsThroughDisk() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            var config = InkstoneConfig.default
            config.notebookRouting = ["Physics 201": "Courses/Physics"]
            try config.write(to: url)
            #expect(try InkstoneConfig.load(from: url).notebookRouting
                    == ["Physics 201": "Courses/Physics"])
        }
    }

    @Test func missingFileYieldsDefaults() throws {
        let config = try InkstoneConfig.load(from: URL(fileURLWithPath: "/nonexistent/x.json"))
        #expect(config.renderDPI == InkstoneConfig.default.renderDPI)
    }

    @Test func expandsTilde() {
        var config = InkstoneConfig.default
        config.vaultPath = "~/Vault"
        #expect(!config.vaultURL.path.contains("~"))
    }
}

@Suite("Reading order")
struct LineGroupingTests {

    @Test("Blocks sharing a horizontal band become one line, ordered left to right")
    func blocksOnOneBandJoinOneLine() {
        let blocks = [
            TextBlock(text: "second", confidence: 0.9,
                      boundingBox: CGRect(x: 0.4, y: 0.80, width: 0.2, height: 0.02)),
            TextBlock(text: "first", confidence: 0.9,
                      boundingBox: CGRect(x: 0.1, y: 0.81, width: 0.2, height: 0.02)),
            TextBlock(text: "below", confidence: 0.9,
                      boundingBox: CGRect(x: 0.1, y: 0.70, width: 0.2, height: 0.02)),
        ]
        let lines = VisionOCR.groupIntoLines(blocks)

        #expect(lines.count == 2)
        #expect(lines[0].text == "first second")
        #expect(lines[1].text == "below")
    }

    @Test("Line order is top-down regardless of the order Vision returned them")
    func linesAreOrderedTopDown() {
        let blocks = (0..<5).map { index in
            TextBlock(text: "l\(index)", confidence: 0.9,
                      boundingBox: CGRect(x: 0.1, y: 0.9 - Double(index) * 0.1,
                                          width: 0.2, height: 0.02))
        }
        #expect(VisionOCR.groupIntoLines(blocks.shuffled()).map(\.text)
                == ["l0", "l1", "l2", "l3", "l4"])
    }

    @Test("A one-character stray does not drag a long line's confidence down")
    func confidenceIsCharacterWeighted() {
        let line = TextLine(blocks: [
            TextBlock(text: "aaaaaaaaaa", confidence: 1.0, boundingBox: .zero),
            TextBlock(text: "b", confidence: 0.0, boundingBox: .zero),
        ])
        #expect(abs(line.confidence - 10.0 / 11.0) < 0.001)
    }

    @Test func emptyInputYieldsNoLines() {
        #expect(VisionOCR.groupIntoLines([]).isEmpty)
    }
}

@Suite("Markdown")
struct MarkdownBuilderTests {

    private let builder = MarkdownBuilder()

    @Test func headingsBulletsAndTasks() {
        let markdown = builder.markdown(for: [
            Fixtures.line("Chapter One", y: 0.05, height: 0.04),
            Fixtures.line("- first point", y: 0.12, height: 0.02),
            Fixtures.line("• second point", y: 0.15, height: 0.02),
            Fixtures.line("1. numbered", y: 0.18, height: 0.02),
            Fixtures.line("[ ] a task", y: 0.21, height: 0.02),
            Fixtures.line("plain text", y: 0.24, height: 0.02),
        ])
        let lines = markdown.split(separator: "\n").map(String.init)

        #expect(lines[0].hasPrefix("#"), "tall line should become a heading: \(lines[0])")
        #expect(lines[1] == "- first point")
        #expect(lines[2] == "- second point")
        #expect(lines[3] == "1. numbered")
        #expect(lines[4] == "- [ ] a task")
        #expect(lines[5] == "plain text")
    }

    @Test("An em dash mid-sentence is not a bullet")
    func dashHeuristics() {
        #expect(MarkdownBuilder.splitBulletMarker("—wait") == nil)
        #expect(MarkdownBuilder.splitBulletMarker("-") == nil)
        #expect(MarkdownBuilder.splitBulletMarker("- yes") == "yes")
    }

    @Test func indentationBecomesNesting() {
        let markdown = builder.markdown(for: [
            Fixtures.line("- top", y: 0.10, x: 0.10),
            Fixtures.line("- nested", y: 0.13, x: 0.19),
        ])
        #expect(markdown == "- top\n  - nested")
    }

    @Test func wideGapStartsANewParagraph() {
        let markdown = builder.markdown(for: [
            Fixtures.line("one", y: 0.10),
            Fixtures.line("two", y: 0.13),
            Fixtures.line("three", y: 0.16),
            Fixtures.line("far below", y: 0.60),
        ])
        #expect(markdown.contains("\n\nfar below"), "\(markdown)")
    }

    @Test func blankRunsCollapse() {
        #expect(MarkdownBuilder.collapseBlankRuns(["a", "", "", "b", ""]) == ["a", "", "b"])
    }

    @Test func emptyInputYieldsEmptyMarkdown() {
        #expect(builder.markdown(for: []).isEmpty)
    }
}

@Suite("Frontmatter")
struct FrontmatterTests {

    @Test("Known keys keep a fixed order so re-runs do not churn the user's diffs")
    func renderUsesStableKeyOrder() {
        let block = Frontmatter.render([
            "tags": .list(["inkstone"]),
            "title": .string("Notes"),
            "pages": .int(3),
            "zzz_custom": .bool(true),
        ])
        let keys = block.split(separator: "\n")
            .filter { $0 != "---" }
            .map { String($0.split(separator: ":")[0]) }
        #expect(keys == ["title", "pages", "tags", "zzz_custom"])
    }

    @Test func quotingOnlyWhereYAMLNeedsIt() {
        #expect(Frontmatter.quote("Physics 201") == "Physics 201")
        #expect(Frontmatter.quote("A: B") == "\"A: B\"")
        #expect(Frontmatter.quote("true") == "\"true\"")
        #expect(Frontmatter.quote("12") == "\"12\"")
        #expect(Frontmatter.quote("say \"hi\"") == "\"say \\\"hi\\\"\"")
    }

    @Test func splitsAndReadsScalars() throws {
        let note = "---\ntitle: Notes\ninkstone_lock: true\n---\n\nbody text\n"
        let (frontmatter, body) = Frontmatter.split(note)
        let block = try #require(frontmatter)
        #expect(Frontmatter.value(of: "inkstone_lock", in: block) == "true")
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "body text")
    }

    @Test func handlesNotesWithoutFrontmatter() {
        let (frontmatter, body) = Frontmatter.split("just a note")
        #expect(frontmatter == nil)
        #expect(body == "just a note")
    }
}

@Suite("Confidence gate")
struct ConfidenceGateTests {

    private func transcript(_ lines: [TextLine]) -> PageTranscript {
        PageTranscript(pageIndex: 0, lines: lines, source: .vision)
    }

    @Test("A near-blank page is a confident nothing, not a failed transcription")
    func blankPageNeverEscalates() {
        let decision = ConfidenceGate(threshold: 0.6, enabled: true)
            .evaluate(transcript([Fixtures.line("hm", y: 0.1, confidence: 0.1)]))
        #expect(!decision.shouldEscalate)
        #expect(decision.score == 1.0)
    }

    @Test func lowConfidenceEscalates() {
        let decision = ConfidenceGate(threshold: 0.6, enabled: true).evaluate(transcript([
            Fixtures.line("a long line of shaky handwriting", y: 0.1, confidence: 0.3),
            Fixtures.line("another shaky line here too", y: 0.2, confidence: 0.25),
        ]))
        #expect(decision.shouldEscalate)
        #expect(!decision.reasons.isEmpty)
    }

    @Test func confidentPageStaysLocal() {
        let decision = ConfidenceGate(threshold: 0.6, enabled: true).evaluate(transcript([
            Fixtures.line("a clean confident line of text", y: 0.1, confidence: 0.97),
            Fixtures.line("and a second clean line here", y: 0.2, confidence: 0.95),
        ]), inkCoverage: 0.02)
        #expect(!decision.shouldEscalate, "reasons: \(decision.reasons)")
    }

    @Test("With escalation off, a bad page is flagged rather than sent anywhere")
    func disabledGateFlagsOnly() {
        let decision = ConfidenceGate(threshold: 0.6, enabled: false).evaluate(transcript([
            Fixtures.line("a long line of shaky handwriting", y: 0.1, confidence: 0.2),
        ]))
        #expect(!decision.shouldEscalate)
        #expect(decision.reasons.contains { $0.contains("disabled") })
    }

    @Test("Dense ink with almost no recognised text escalates even at high confidence")
    func inkCoverageSignalCatchesUnreadPages() {
        let dense = ConfidenceGate(threshold: 0.6, enabled: true).evaluate(
            transcript([Fixtures.line("only these few words", y: 0.1, confidence: 0.98)]),
            inkCoverage: 0.30)
        #expect(dense.shouldEscalate)
        #expect(dense.reasons.contains { $0.contains("dense ink") })
    }

    @Test func garbageRatioSeparatesTextFromNoise() {
        let clean = transcript([Fixtures.line("hello there friend", y: 0.1)])
        let noisy = transcript([Fixtures.line("h€||◊ ¶∞≈ ††† ◊◊◊", y: 0.1)])
        #expect(ConfidenceGate.garbageRatio(clean) < 0.05)
        #expect(ConfidenceGate.garbageRatio(noisy) > 0.3)
    }
}

@Suite("Note composition")
struct NoteComposerTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        config.notebookRouting = ["Physics 201": "Courses/Physics"]
        return config
    }

    @Test func routingMatchesPrefixCaseInsensitively() {
        let composer = NoteComposer(config: config)
        #expect(composer.route(notebook: "Physics 201") == "Courses/Physics")
        #expect(composer.route(notebook: "physics 201 — term 2") == "Courses/Physics")
        #expect(composer.route(notebook: "Recipes") == "Inkstone")
    }

    @Test func fileNamesAreVaultSafe() {
        #expect(NoteComposer.safeFileName("A/B:C*D?") == "A-B-C-D-")
        #expect(NoteComposer.safeFileName("   ") == "Untitled")
        #expect(NoteComposer.slug("Physics 201 — Term 2") == "physics-201-term-2")
    }

    @Test("A diagram lands between the lines it sat between on the page")
    func diagramsInterleaveByPosition() {
        let transcript = PageTranscript(
            pageIndex: 0,
            lines: [Fixtures.line("above the sketch", y: 0.10),
                    Fixtures.line("below the sketch", y: 0.70)],
            source: .vision,
            diagrams: [DiagramCrop(pageIndex: 0, index: 0, pixelRect: .zero,
                                   anchorTopDownY: 0.40, fileName: "sketch.png")])
        let lines = NoteComposer(config: config).pageBody(transcript)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        #expect(lines == ["above the sketch", "![[sketch.png]]", "below the sketch"])
    }

    @Test func vlmPlaceholdersAreSubstitutedInOrder() {
        let diagrams = (0..<2).map {
            DiagramCrop(pageIndex: 0, index: $0, pixelRect: .zero,
                        anchorTopDownY: Double($0), fileName: "d\($0).png")
        }
        let markdown = NoteComposer.substitutePlaceholders(
            in: "one\n\(NoteComposer.diagramPlaceholder)\ntwo\n\(NoteComposer.diagramPlaceholder)",
            with: diagrams)
        #expect(markdown == "one\n![[d0.png]]\ntwo\n![[d1.png]]")
    }

    @Test("A diagram the model ignored is appended, never dropped")
    func unusedDiagramsAreAppended() {
        let diagrams = [DiagramCrop(pageIndex: 0, index: 0, pixelRect: .zero,
                                    anchorTopDownY: 0, fileName: "d.png")]
        let markdown = NoteComposer.substitutePlaceholders(in: "no placeholder", with: diagrams)
        #expect(markdown.hasSuffix("![[d.png]]"), "\(markdown)")
    }

    @Test func lowConfidencePagesAreFlaggedInFrontmatter() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes",
            sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [
                PageOutput(pageIndex: 0, markdown: "fine", confidence: 0.95, source: .vision),
                PageOutput(pageIndex: 1, markdown: "murky", confidence: 0.10, source: .vision),
            ])

        #expect(notes.count == 1)
        #expect(notes[0].lowConfidencePages == [2])
        #expect(notes[0].frontmatter["needs_review"] == .bool(true))
        #expect(notes[0].contents.contains("## Page 1"))
        #expect(notes[0].contents.contains("## Page 2"))
    }

    @Test func pageGranularityProducesOneNotePerPage() {
        let notes = NoteComposer(config: config, granularity: .page).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: (0..<3).map {
                PageOutput(pageIndex: $0, markdown: "page \($0)", confidence: 0.9, source: .vision)
            })
        #expect(notes.count == 3)
        #expect(notes[1].relativePath == "Inkstone/Recipes/Recipes — p2.md")
    }

    @Test func blankPagesAreLabelledNotOmitted() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "  ", confidence: 1, source: .vision)])
        #expect(notes[0].contents.contains("*(blank page)*"))
    }
}

@Suite("Cloud escalation")
struct VLMClientTests {

    @Test func extractsTextBlocks() throws {
        let body = Data(##"{"content":[{"type":"text","text":"# Title\nbody"}]}"##.utf8)
        #expect(try VLMClient.extractText(from: body) == "# Title\nbody")
    }

    @Test("A model that wraps its answer in a fence does not corrupt the note")
    func stripsAWrappingCodeFence() {
        #expect(VLMClient.stripCodeFence("```markdown\n# Title\n```") == "# Title")
        #expect(VLMClient.stripCodeFence("# Title") == "# Title")
    }

    @Test func surfacesAPIErrorMessage() {
        #expect(VLMClient.errorMessage(Data(##"{"error":{"message":"overloaded"}}"##.utf8))
                == "overloaded")
    }

    @Test func emptyContentIsAnError() {
        #expect(throws: (any Error).self) {
            try VLMClient.extractText(from: Data(##"{"content":[]}"##.utf8))
        }
    }

    @Test func backoffGrowsAndIsCapped() {
        #expect(VLMClient.backoff(attempt: 1) < VLMClient.backoff(attempt: 3))
        #expect(VLMClient.backoff(attempt: 12) <= 31)
    }

    @Test func promptDemandsPlaceholdersWhenDiagramsExist() {
        let prompt = VLMPrompt.user(pageNumber: 3, notebook: "Physics",
                                    hasDiagrams: 2, visionDraft: "draft text")
        #expect(prompt.contains(NoteComposer.diagramPlaceholder))
        #expect(prompt.contains("exactly 2"))
        #expect(prompt.contains("<draft>"))
    }

    @Test func promptOmitsDiagramSectionWhenThereAreNone() {
        let prompt = VLMPrompt.user(pageNumber: 1, notebook: "N", hasDiagrams: 0, visionDraft: nil)
        #expect(!prompt.contains(NoteComposer.diagramPlaceholder))
        #expect(!prompt.contains("<draft>"))
    }

    @Test("No API key means no client, not a crash")
    func noClientWithoutAKey() {
        var config = InkstoneConfig.default
        config.cloudEscalationEnabled = true
        #expect(VLMClient.make(config: config, environment: [:]) == nil)
        #expect(VLMClient.make(config: config, environment: ["ANTHROPIC_API_KEY": "k"]) != nil)
    }
}

@Suite("launchd")
struct LaunchAgentTests {

    @Test("The generated plist parses and escapes shell-hostile paths")
    func plistIsWellFormedAndEscaped() throws {
        let plist = LaunchAgent.plist(
            label: "com.inkstone.test",
            arguments: ["/opt/A & B/inkstone", "run"],
            extra: "    <key>RunAtLoad</key>\n    <true/>")

        #expect(plist.contains("&amp;"))
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(plist.utf8), format: nil) as? [String: Any]
        #expect(parsed?["Label"] as? String == "com.inkstone.test")
        #expect((parsed?["ProgramArguments"] as? [String])?.first == "/opt/A & B/inkstone")
        #expect(parsed?["RunAtLoad"] as? Bool == true)
    }
}

@Suite("Inbox scanning")
struct InboxScanTests {

    @Test("Finds PDFs recursively and skips cloud placeholders")
    func findsPDFsAndSkipsPlaceholders() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("Sub")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            try Fixtures.makePDF(at: directory.appendingPathComponent("A.pdf"),
                                 title: "A", pages: [.init(lines: ["hello"])])
            try Fixtures.makePDF(at: nested.appendingPathComponent("B.pdf"),
                                 title: "B", pages: [.init(lines: ["hello"])])
            // A Google Drive placeholder: a real path with near-zero bytes.
            try Data("x".utf8).write(to: directory.appendingPathComponent("stub.pdf"))
            try Data().write(to: directory.appendingPathComponent("notes.txt"))

            #expect(try Pipeline.findPDFs(in: directory).map(\.lastPathComponent) == ["A.pdf", "B.pdf"])
        }
    }

    @Test func missingInboxThrows() {
        #expect(throws: (any Error).self) {
            try Pipeline.findPDFs(in: URL(fileURLWithPath: "/no/such/inbox"))
        }
    }

    @Test func recognisesCloudProviders() {
        #expect(Doctor.cloudProvider(
            for: URL(fileURLWithPath: "/Users/x/Library/CloudStorage/GoogleDrive-a/My Drive/GN"))
            == "Google Drive")
        #expect(Doctor.cloudProvider(for: URL(fileURLWithPath: "/Users/x/Notes")) == nil)
    }
}
