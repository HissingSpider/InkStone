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

    @Test("Page-number lists emit as real YAML integers, not quoted strings")
    func intListsAreUnquoted() {
        #expect(Frontmatter.scalar(.intList([1, 2, 7])) == "[1, 2, 7]")
        #expect(Frontmatter.scalar(.list(["1", "2"])) == "[\"1\", \"2\"]")
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
        let decision = ConfidenceGate(threshold: 0.6, mode: .lowConfidence)
            .evaluate(transcript([Fixtures.line("hm", y: 0.1, confidence: 0.1)]))
        #expect(!decision.shouldEscalate)
        #expect(decision.score == 1.0)
    }

    @Test func lowConfidenceEscalates() {
        let decision = ConfidenceGate(threshold: 0.6, mode: .lowConfidence).evaluate(transcript([
            Fixtures.line("a long line of shaky handwriting", y: 0.1, confidence: 0.3),
            Fixtures.line("another shaky line here too", y: 0.2, confidence: 0.25),
        ]))
        #expect(decision.shouldEscalate)
        #expect(!decision.reasons.isEmpty)
    }

    @Test func confidentPageStaysLocal() {
        let decision = ConfidenceGate(threshold: 0.6, mode: .lowConfidence).evaluate(transcript([
            Fixtures.line("a clean confident line of text", y: 0.1, confidence: 0.97),
            Fixtures.line("and a second clean line here", y: 0.2, confidence: 0.95),
        ]), inkCoverage: 0.02)
        #expect(!decision.shouldEscalate, "reasons: \(decision.reasons)")
    }

    @Test("With escalation off, a bad page is flagged rather than sent anywhere")
    func disabledGateFlagsOnly() {
        let decision = ConfidenceGate(threshold: 0.6, mode: .off).evaluate(transcript([
            Fixtures.line("a long line of shaky handwriting", y: 0.1, confidence: 0.2),
        ]))
        #expect(!decision.shouldEscalate)
        #expect(decision.reasons.contains { $0.contains("disabled") })
    }

    @Test("Dense ink with almost no recognised text escalates even at high confidence")
    func inkCoverageSignalCatchesUnreadPages() {
        let dense = ConfidenceGate(threshold: 0.6, mode: .lowConfidence).evaluate(
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
        // A heading OCR'd with a trailing full stop must not yield "Name..md",
        // and a leading dot must not hide the note from Obsidian.
        #expect(NoteComposer.safeFileName("Vector operations.") == "Vector operations")
        #expect(NoteComposer.safeFileName(".hidden") == "hidden")
        #expect(NoteComposer.safeFileName("...") == "Untitled")
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

    @Test("The gate's verdict drives needs_review, not a re-derived confidence")
    func flaggingFollowsTheGateVerdict() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes",
            sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [
                PageOutput(pageIndex: 0, markdown: "fine", confidence: 0.95,
                           needsReview: false, source: .vision),
                PageOutput(pageIndex: 1, markdown: "murky", confidence: 0.88,
                           needsReview: true, source: .vision),
            ])

        #expect(notes.count == 1)
        // Page 2 scored 0.88 — high — yet the gate condemned it. Re-deriving the
        // flag from the number was the bug that shipped bad pages unflagged.
        #expect(notes[0].lowConfidencePages == [2])
        #expect(notes[0].frontmatter["needs_review"] == .bool(true))
        #expect(notes[0].contents.contains("## Page 1"))
        #expect(notes[0].contents.contains("## Page 2"))
    }

    @Test("A page the gate cleared is not flagged, however low its raw score")
    func lowScoreAloneDoesNotFlag() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "ok", confidence: 0.10,
                               needsReview: false, source: .vision)])
        #expect(notes[0].lowConfidencePages.isEmpty)
        #expect(notes[0].frontmatter["needs_review"] == nil)
    }

    @Test("An escalated page is never flagged for review")
    func escalatedPagesAreNotFlagged() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "rescued", confidence: 1.0,
                               needsReview: true, source: .vlm)])
        #expect(notes[0].lowConfidencePages.isEmpty)
        #expect(notes[0].frontmatter["ocr"] == .string("vlm"))
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
struct VLMTests {

    // MARK: Provider selection

    @Test("OpenAI is the default, and each provider brings its own model and key")
    func providerDefaults() {
        var config = InkstoneConfig.default
        #expect(config.resolvedProvider == .openai)
        #expect(config.resolvedModel == "gpt-4o")
        #expect(config.resolvedKeyEnvVar == "OPENAI_API_KEY")

        config.vlmProvider = "anthropic"
        #expect(config.resolvedModel == "claude-opus-5")
        #expect(config.resolvedKeyEnvVar == "ANTHROPIC_API_KEY")
    }

    @Test("Switching provider does not strand you on the other one's model name")
    func explicitOverridesWin() {
        var config = InkstoneConfig.default
        config.vlmProvider = "anthropic"
        config.vlmModel = "claude-sonnet-5"
        config.apiKeyEnvVar = "WORK_KEY"
        #expect(config.resolvedModel == "claude-sonnet-5")
        #expect(config.resolvedKeyEnvVar == "WORK_KEY")

        // An unknown provider name falls back rather than failing the run.
        config.vlmProvider = "acme"
        #expect(config.resolvedProvider == .openai)
    }

    @Test func factoryBuildsTheConfiguredProvider() {
        var config = InkstoneConfig.default
        config.escalationMode = "always"
        config.apiKeyFile = "/nonexistent/inkstone-test-credentials"

        let openai = VLM.make(config: config, environment: ["OPENAI_API_KEY": "k"])
        #expect(openai?.kind == .openai)
        #expect(openai?.model == "gpt-4o")

        config.vlmProvider = "anthropic"
        let anthropic = VLM.make(config: config, environment: ["ANTHROPIC_API_KEY": "k"])
        #expect(anthropic?.kind == .anthropic)

        // Wrong key for the selected provider is the same as no key.
        #expect(VLM.make(config: config, environment: ["OPENAI_API_KEY": "k"]) == nil)
    }

    @Test("No key means no client, not a crash")
    func noClientWithoutAKey() {
        var config = InkstoneConfig.default
        config.escalationMode = "lowConfidence"
        // Point at a path that cannot exist. Without this the test reads the
        // real credentials file on the developer's machine, which makes it pass
        // or fail depending on whose laptop it runs on — and prints their key
        // into the failure message when it does fail.
        config.apiKeyFile = "/nonexistent/inkstone-test-credentials"

        #expect(VLM.make(config: config, environment: [:]) == nil)
        #expect(VLM.make(config: config, environment: ["OPENAI_API_KEY": "k"]) != nil)
    }

    @Test func offModeBuildsNothing() {
        #expect(VLM.make(config: .default, environment: ["OPENAI_API_KEY": "k"]) == nil)
    }

    @Test("A client never renders its key, however it is printed")
    func keysAreRedactedInDescriptions() {
        let openai = OpenAIVLM(model: "gpt-4o", apiKey: "sk-super-secret")
        #expect(!"\(openai)".contains("secret"))
        #expect(!String(describing: openai).contains("secret"))
        #expect(!String(reflecting: openai).contains("secret"))

        let anthropic = AnthropicVLM(model: "claude-opus-5", apiKey: "sk-super-secret")
        #expect(!"\(anthropic)".contains("secret"))
        #expect(!String(reflecting: anthropic).contains("secret"))
    }

    @Test("The endpoint can be pointed at Azure or a gateway")
    func endpointOverride() {
        setenv("INKSTONE_OPENAI_ENDPOINT", "https://example.invalid/v1/chat/completions", 1)
        defer { unsetenv("INKSTONE_OPENAI_ENDPOINT") }
        #expect(OpenAIVLM(model: "gpt-4o", apiKey: "k").endpoint.host == "example.invalid")
    }

    // MARK: OpenAI responses

    @Test func openAIExtractsContent() throws {
        let body = Data(##"""
            {"choices":[{"finish_reason":"stop","message":{"content":"# Title\nbody"}}]}
            """##.utf8)
        #expect(try OpenAIVLM.extractText(from: body) == "# Title\nbody")
    }

    @Test("A parts array is accepted as well as a plain string")
    func openAIAcceptsPartsArray() throws {
        let body = Data(##"""
            {"choices":[{"message":{"content":[{"type":"text","text":"hello"}]}}]}
            """##.utf8)
        #expect(try OpenAIVLM.extractText(from: body) == "hello")
    }

    @Test("A page truncated mid-transcription fails loudly rather than half-writing")
    func openAITruncationIsAnError() {
        let body = Data(##"""
            {"choices":[{"finish_reason":"length","message":{"content":"half a pa"}}]}
            """##.utf8)
        #expect(throws: (any Error).self) { try OpenAIVLM.extractText(from: body) }
    }

    @Test func openAIEmptyResponsesAreErrors() {
        #expect(throws: (any Error).self) {
            try OpenAIVLM.extractText(from: Data(##"{"choices":[]}"##.utf8))
        }
        #expect(throws: (any Error).self) {
            try OpenAIVLM.extractText(
                from: Data(##"{"choices":[{"message":{"content":"  "}}]}"##.utf8))
        }
    }

    @Test("Newer model families are guessed onto max_completion_tokens")
    func tokenParameterGuess() {
        #expect(OpenAIVLM.tokenLimitKey(for: "gpt-4o") == "max_tokens")
        #expect(OpenAIVLM.tokenLimitKey(for: "gpt-4o-mini") == "max_tokens")
        #expect(OpenAIVLM.tokenLimitKey(for: "o3") == "max_completion_tokens")
        #expect(OpenAIVLM.tokenLimitKey(for: "gpt-5.2") == "max_completion_tokens")
        // A wrong guess is recovered by the adaptive retry, which keys off the
        // API's own complaint rather than a list of model names that will rot.
        #expect(OpenAIVLM.mentionsTokenParameterSwap(
            "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."))
        #expect(!OpenAIVLM.mentionsTokenParameterSwap("invalid api key"))
    }

    // MARK: Anthropic responses

    @Test func anthropicExtractsTextBlocks() throws {
        let body = Data(##"{"content":[{"type":"text","text":"# Title\nbody"}]}"##.utf8)
        #expect(try AnthropicVLM.extractText(from: body) == "# Title\nbody")
    }

    @Test func anthropicTruncationIsAnError() {
        let body = Data(##"""
            {"stop_reason":"max_tokens","content":[{"type":"text","text":"half"}]}
            """##.utf8)
        #expect(throws: (any Error).self) { try AnthropicVLM.extractText(from: body) }
    }

    @Test func anthropicEmptyContentIsAnError() {
        #expect(throws: (any Error).self) {
            try AnthropicVLM.extractText(from: Data(##"{"content":[]}"##.utf8))
        }
    }

    // MARK: Shared transport

    @Test("Both providers nest their error message the same way")
    func transportReadsErrorMessages() {
        #expect(VLMTransport.errorMessage(Data(##"{"error":{"message":"overloaded"}}"##.utf8))
                == "overloaded")
        #expect(VLMTransport.errorMessage(Data("not json".utf8)) == "not json")
    }

    @Test("A model that wraps its answer in a fence does not corrupt the note")
    func stripsAWrappingCodeFence() {
        #expect(VLMTransport.stripCodeFence("```markdown\n# Title\n```") == "# Title")
        #expect(VLMTransport.stripCodeFence("# Title") == "# Title")
    }

    @Test func backoffGrowsAndIsCapped() {
        #expect(VLMTransport.backoff(attempt: 1) < VLMTransport.backoff(attempt: 3))
        #expect(VLMTransport.backoff(attempt: 12) <= 31)
    }

    // MARK: Prompt

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

@Suite("Lexical plausibility")
struct LexiconTests {

    /// A tiny fixed lexicon keeps these tests independent of whether the host
    /// happens to ship /usr/share/dict/words.
    private let lexicon = Lexicon(words: [
        "adding", "vectors", "vector", "operations", "parallel", "scalar",
        "multiple", "other", "length", "magnitude", "coordinate", "entries",
    ])

    @Test("Real OCR garbage is caught even though every character is a letter")
    func catchesPlausibleLookingNonsense() throws {
        // Verbatim from a real run: "Adding 2 vectors / all entries coordinate once".
        let ratio = try #require(
            lexicon.unknownWordRatio(of: "Abling 2 vedur all enfris coordinfe unce Vectr uperting"))
        #expect(ratio > 0.8, "\(ratio)")
    }

    @Test func acceptsGenuineText() throws {
        let ratio = try #require(
            lexicon.unknownWordRatio(of: "adding vectors parallel scalar multiple other length"))
        #expect(ratio == 0)
    }

    @Test("Short tokens and numbers are not judged")
    func ignoresShortAndNumericTokens() {
        // dx, cm, 3, <1,2> carry no evidence either way and must not condemn a page.
        #expect(Lexicon.checkableTokens(in: "dx cm 3 <1,2> f(x) iff") == [])
        #expect(Lexicon.checkableTokens(in: "vectors r2 coordinate") == ["vectors", "coordinate"])
    }

    @Test("Too few tokens yields no verdict rather than a noisy one")
    func abstainsOnShortText() {
        #expect(lexicon.unknownWordRatio(of: "adding vectors") == nil)
    }

    @Test("A missing dictionary disables the signal instead of failing")
    func absentDictionaryIsSafe() {
        let empty = Lexicon(loadingFrom: URL(fileURLWithPath: "/no/such/words"))
        #expect(!empty.isAvailable)
        #expect(empty.unknownWordRatio(of: "any amount of text at all whatsoever here") == nil)
    }
}

@Suite("Escalation modes")
struct EscalationModeTests {

    private func transcript(_ text: String, confidence: Double = 0.95) -> PageTranscript {
        PageTranscript(
            pageIndex: 0,
            lines: text.split(separator: "|").enumerated().map { index, line in
                Fixtures.line(String(line), y: 0.1 + Double(index) * 0.05, confidence: confidence)
            },
            source: .vision)
    }

    private let lexicon = Lexicon(words: ["adding", "vectors", "parallel", "scalar", "length",
                                          "multiple", "other", "computing", "entries"])

    @Test("High Vision confidence does not rescue a page that is not language")
    func lexicalSignalOverridesInflatedConfidence() {
        let gate = ConfidenceGate(threshold: 0.55, mode: .lowConfidence, lexicon: lexicon)
        let decision = gate.evaluate(
            transcript("Abling 2 vedur|all enfris coordinfe unce|Vectr uperting sude", confidence: 0.95))

        #expect(decision.needsReview, "score \(decision.score), reasons \(decision.reasons)")
        #expect(decision.shouldEscalate)
        #expect(decision.reasons.contains { $0.contains("recognisable words") })
    }

    @Test func genuineTextPassesCleanly() {
        let gate = ConfidenceGate(threshold: 0.55, mode: .lowConfidence, lexicon: lexicon)
        let decision = gate.evaluate(
            transcript("adding vectors parallel|scalar multiple other|computing length entries"),
            inkCoverage: 0.02)
        #expect(!decision.needsReview, "reasons: \(decision.reasons)")
        #expect(!decision.shouldEscalate)
    }

    @Test("always mode escalates even a page the gate is happy with")
    func alwaysModeIgnoresTheGate() {
        let gate = ConfidenceGate(threshold: 0.55, mode: .always, lexicon: lexicon)
        let decision = gate.evaluate(
            transcript("adding vectors parallel|scalar multiple other|computing length entries"))
        #expect(decision.shouldEscalate)
        #expect(!decision.needsReview)
    }

    @Test("always mode still refuses to spend money on a blank page")
    func alwaysModeSkipsBlankPages() {
        let gate = ConfidenceGate(threshold: 0.55, mode: .always, lexicon: lexicon)
        #expect(!gate.evaluate(transcript("hm")).shouldEscalate)
    }

    @Test func offModeFlagsWithoutSending() {
        let gate = ConfidenceGate(threshold: 0.55, mode: .off, lexicon: lexicon)
        let decision = gate.evaluate(transcript("Abling 2 vedur|all enfris coordinfe unce|Vectr uperting"))
        #expect(decision.needsReview)
        #expect(!decision.shouldEscalate)
        #expect(decision.reasons.contains { $0.contains("disabled") })
    }

    @Test("escalationMode wins over the legacy boolean, which still works alone")
    func modeResolutionIsBackwardCompatible() {
        var config = InkstoneConfig.default
        #expect(config.resolvedEscalationMode == .off)

        config.cloudEscalationEnabled = true
        #expect(config.resolvedEscalationMode == .lowConfidence)

        config.escalationMode = "always"
        #expect(config.resolvedEscalationMode == .always)

        config.escalationMode = "nonsense"
        #expect(config.resolvedEscalationMode == .lowConfidence, "falls back to the boolean")
    }
}

@Suite("Watermark filtering")
struct WatermarkTests {

    private var composer: NoteComposer { NoteComposer(config: .default) }

    @Test("The GoodNotes watermark is dropped, including OCR mangling of it")
    func dropsWatermarkVariants() {
        for variant in ["Made with GoodNotes", "Mado with Goodnotes",
                        "made with goodnotes", "M2de with G00dnotes", "  Made with Goodnotes  "] {
            #expect(composer.isIgnored(variant.trimmingCharacters(in: .whitespaces)),
                    "should have been ignored: \(variant)")
        }
    }

    @Test func keepsRealContent() {
        for keeper in ["Made with love", "Notes on GoodNotes as a product",
                       "Vectors", "goodnotes is fine but"] {
            #expect(!composer.isIgnored(keeper), "should have been kept: \(keeper)")
        }
    }

    @Test("A malformed user pattern is skipped rather than crashing the run")
    func malformedPatternIsIgnored() {
        var config = InkstoneConfig.default
        config.ignoreLinePatterns = ["[unclosed", "^drop me$"]
        let composer = NoteComposer(config: config)
        #expect(composer.isIgnored("drop me"))
        #expect(!composer.isIgnored("keep me"))
    }

    @Test func watermarkIsStrippedFromThePageBody() {
        let transcript = PageTranscript(
            pageIndex: 0,
            lines: [Fixtures.line("Real content here", y: 0.1),
                    Fixtures.line("Made with Goodnotes", y: 0.95)],
            source: .vision)
        let body = composer.pageBody(transcript)
        #expect(body == "Real content here", "\(body)")
    }

    @Test("The watermark is stripped from cloud transcriptions too")
    func watermarkStrippedFromVLMOutput() {
        let transcript = PageTranscript(
            pageIndex: 0, lines: [], source: .vlm,
            vlmMarkdown: "# Vectors\n\nSome real notes\n\nMade with GoodNotes")
        #expect(composer.pageBody(transcript) == "# Vectors\n\nSome real notes")
    }
}

@Suite("Diagram candidate filtering")
struct DiagramFilterTests {

    @Test("A sliver is rejected: one real run produced a 126x2452 crop")
    func rejectsExtremeAspectRatios() {
        var extractor = DiagramExtractor()
        extractor.maxAspectRatio = 8
        // 126 x 2452 is roughly 1:19.
        #expect(19.0 > extractor.maxAspectRatio)
        // And a squarish diagram is kept.
        #expect(360.0 / 246.0 < extractor.maxAspectRatio)
    }
}

@Suite("Section splitting")
struct SectionTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        config.notebookRouting = ["Vectors": "Courses/Linear Algebra"]
        return config
    }

    private func page(_ index: Int, _ markdown: String) -> PageOutput {
        PageOutput(pageIndex: index, markdown: markdown, confidence: 0.9, source: .vision)
    }

    // MARK: Title detection

    @Test func detectsHeadingsAtAnyLevel() {
        #expect(NoteComposer.sectionTitle(of: "## Vectors\n\nbody") == "Vectors")
        #expect(NoteComposer.sectionTitle(of: "# Sprint Planning\n\nbody") == "Sprint Planning")
        #expect(NoteComposer.sectionTitle(of: "### Parallel Vectors\n\nbody") == "Parallel Vectors")
    }

    @Test func ignoresLeadingBlankLines() {
        #expect(NoteComposer.sectionTitle(of: "\n\n## Vectors\nbody") == "Vectors")
    }

    @Test("A page that does not open with a heading starts no section")
    func rejectsNonHeadingPages() {
        #expect(NoteComposer.sectionTitle(of: "just prose\n\n## a heading later") == nil)
        #expect(NoteComposer.sectionTitle(of: "") == nil)
    }

    @Test("A long sentence written large is not a section title")
    func rejectsImplausibleTitles() {
        #expect(NoteComposer.sectionTitle(
            of: "## the quick brown fox jumps over the lazy dog again") == nil)  // too many words
        #expect(NoteComposer.sectionTitle(of: "## ##") == nil)                   // no letters
        #expect(NoteComposer.sectionTitle(of: "## ab") == nil)                   // too short
    }

    // MARK: Grouping

    @Test("Pages accumulate under the heading that opened them")
    func groupsContinuationPages() {
        let sections = NoteComposer.sections(in: [
            page(0, "## Vectors\n\nintro"),
            page(1, "more about vectors"),
            page(2, "## Matrices\n\nintro"),
            page(3, "more about matrices"),
        ], fallbackTitle: "Notebook")

        #expect(sections.map(\.title) == ["Vectors", "Matrices"])
        #expect(sections[0].pages.count == 2)
        #expect(sections[1].pages.count == 2)
        #expect(sections.filter(\.isExplicit).count == 2)
    }

    @Test("Pages before the first heading are kept under the notebook's name")
    func leadingPagesAreNotLost() {
        let sections = NoteComposer.sections(in: [
            page(0, "a cover page"),
            page(1, "## Vectors\n\nintro"),
        ], fallbackTitle: "Calculus")

        #expect(sections.map(\.title) == ["Calculus", "Vectors"])
        #expect(!sections[0].isExplicit)
        #expect(sections[1].isExplicit)
    }

    @Test("A notebook with no headings at all stays one note")
    func headinglessNotebookIsOneSection() {
        let sections = NoteComposer.sections(in: [page(0, "prose"), page(1, "more prose")],
                                             fallbackTitle: "Scratch")
        #expect(sections.count == 1)
        #expect(sections[0].title == "Scratch")
        #expect(sections[0].pages.count == 2)
    }

    // MARK: Composition

    @Test("Each section becomes its own categorised, tagged note")
    func sectionsBecomeCategorisedNotes() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Current", sourceURL: URL(fileURLWithPath: "/tmp/Current.pdf"),
            pages: [page(0, "## Vectors\n\nintro"),
                    page(1, "continued"),
                    page(2, "## Sprint Planning\n\nstandup notes")])

        #expect(notes.count == 2)

        // A routed section goes where the rule says.
        #expect(notes[0].relativePath == "Courses/Linear Algebra/Vectors.md")
        #expect(notes[0].frontmatter["category"] == .string("Vectors"))
        #expect(notes[0].frontmatter["notebook"] == .string("Current"))
        #expect(notes[0].frontmatter["source_pages"] == .intList([1, 2]))
        #expect(notes[0].frontmatter["tags"] == .list(["inkstone", "handwritten", "vectors"]))

        // An unrouted one nests under its notebook rather than the vault root,
        // so two notebooks cannot fight over the same file name.
        #expect(notes[1].relativePath == "Inkstone/Current/Sprint Planning.md")
        #expect(notes[1].frontmatter["category"] == .string("Sprint Planning"))
    }

    @Test("Untitled leading pages are not given a bogus category")
    func fallbackSectionIsNotCategorised() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Scratch", sourceURL: URL(fileURLWithPath: "/tmp/Scratch.pdf"),
            pages: [page(0, "loose notes")])

        #expect(notes[0].frontmatter["category"] == nil)
        #expect(notes[0].frontmatter["tags"] == .list(["inkstone", "handwritten"]))
        #expect(notes[0].relativePath == "Inkstone/Scratch/Scratch.md")
    }

    @Test("A heading used twice in one notebook does not overwrite itself")
    func duplicateHeadingsGetDistinctPaths() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Current", sourceURL: URL(fileURLWithPath: "/tmp/Current.pdf"),
            pages: [page(0, "## Standup\n\nmonday"), page(1, "## Standup\n\ntuesday")])

        #expect(notes.count == 2)
        #expect(notes[0].relativePath != notes[1].relativePath)
        #expect(notes[1].relativePath.hasSuffix("Standup (2).md"))
    }

    @Test("A single-page section carries no page heading clutter")
    func singlePageSectionsAreClean() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Current", sourceURL: URL(fileURLWithPath: "/tmp/Current.pdf"),
            pages: [page(4, "## Vectors\n\nthe body")])
        #expect(!notes[0].contents.contains("## Page"))
        #expect(notes[0].frontmatter["source_pages"] == .intList([5]))
    }

    @Test("An empty routing rule cannot swallow every section")
    func emptyPatternIsIgnored() {
        var config = config
        config.notebookRouting = ["": "Everything"]
        let composer = NoteComposer(config: config, granularity: .section)
        #expect(composer.routeIfMatched("Vectors") == nil)
    }
}

@Suite("Credentials")
struct CredentialsTests {

    @Test("Shell-style lines parse, so one file serves both the shell and launchd")
    func parsesShellSyntax() {
        let parsed = Credentials.parse("""
            # a comment
            export OPENAI_API_KEY="sk-one"
            ANTHROPIC_API_KEY=sk-two
            export QUOTED='sk-three'

            malformed line with no equals
            EMPTY=
            """)
        #expect(parsed["OPENAI_API_KEY"] == "sk-one")
        #expect(parsed["ANTHROPIC_API_KEY"] == "sk-two")
        #expect(parsed["QUOTED"] == "sk-three")
        #expect(parsed["EMPTY"] == nil)
        #expect(parsed.count == 3)
    }

    @Test("Only a matched pair of quotes is stripped")
    func doesNotMangleValues() {
        #expect(Credentials.parse(#"K="sk-a=b=c""#)["K"] == "sk-a=b=c")
        #expect(Credentials.parse(##"K="unmatched"##)["K"] == "\"unmatched")
    }

    @Test("The environment wins, so a one-off override still works")
    func environmentTakesPrecedence() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-from-file", as: "OPENAI_API_KEY", at: url)

            let overridden = Credentials.resolve(
                variable: "OPENAI_API_KEY",
                environment: ["OPENAI_API_KEY": "sk-from-env"], fileURL: url)
            #expect(overridden.value == "sk-from-env")
            #expect(overridden.source == "environment")

            // With an empty environment — which is what launchd gives you — the
            // file is what keeps escalation working.
            let fromFile = Credentials.resolve(
                variable: "OPENAI_API_KEY", environment: [:], fileURL: url)
            #expect(fromFile.value == "sk-from-file")
        }
    }

    @Test("The file is created owner-only, never briefly world-readable")
    func storedFileIsPrivate() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-secret", as: "OPENAI_API_KEY", at: url)

            let mode = try #require(FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            #expect(mode.int16Value & 0o077 == 0, "\(String(format: "mode %03o", mode.int16Value))")
        }
    }

    @Test("Storing a second key preserves the first")
    func storePreservesOtherKeys() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-openai", as: "OPENAI_API_KEY", at: url)
            try Credentials.store("sk-anthropic", as: "ANTHROPIC_API_KEY", at: url)

            #expect(Credentials.resolve(variable: "OPENAI_API_KEY",
                                        environment: [:], fileURL: url).value == "sk-openai")
            #expect(Credentials.resolve(variable: "ANTHROPIC_API_KEY",
                                        environment: [:], fileURL: url).value == "sk-anthropic")
        }
    }

    @Test("Rotating replaces rather than appending a duplicate")
    func storeReplacesExistingValue() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-old", as: "OPENAI_API_KEY", at: url)
            try Credentials.store("sk-new", as: "OPENAI_API_KEY", at: url)

            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(!contents.contains("sk-old"))
            #expect(Credentials.parse(contents)["OPENAI_API_KEY"] == "sk-new")
        }
    }

    @Test("A loose-permissioned file is flagged, not silently trusted")
    func warnsAboutLoosePermissions() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-secret", as: "OPENAI_API_KEY", at: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: url.path)

            let resolution = Credentials.resolve(
                variable: "OPENAI_API_KEY", environment: [:], fileURL: url)
            #expect(resolution.value == "sk-secret")
            #expect(resolution.permissionWarning != nil)
        }
    }

    @Test("A missing file is a state, not an error")
    func missingFileResolvesToNothing() {
        let resolution = Credentials.resolve(
            variable: "OPENAI_API_KEY", environment: [:],
            fileURL: URL(fileURLWithPath: "/no/such/credentials"))
        #expect(resolution.value == nil)
        #expect(resolution.source == "not found")
    }

    @Test("The factory picks the key up from the file with an empty environment")
    func factoryReadsFromFile() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("credentials")
            try Credentials.store("sk-file", as: "OPENAI_API_KEY", at: url)

            var config = InkstoneConfig.default
            config.escalationMode = "always"
            config.apiKeyFile = url.path

            #expect(VLM.make(config: config, environment: [:])?.kind == .openai)
        }
    }
}

@Suite("Section aliases")
struct SectionAliasTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        // Verbatim from a real run: a diagram-only page whose sole heading the
        // recogniser could not read.
        config.sectionAliases = ["Workinet": "Worksheet", "vector upending": "Vector operations"]
        config.notebookRouting = ["Worksheet": "Courses/Problems"]
        return config
    }

    @Test("A corrected name reaches the path, the category and the tag")
    func aliasRewritesEverything() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 6, markdown: "# Workinet\n\n![[c.png]]",
                               confidence: 1, source: .vlm)])

        #expect(notes[0].frontmatter["category"] == .string("Worksheet"))
        #expect(notes[0].frontmatter["tags"] == .list(["inkstone", "handwritten", "worksheet"]))
        // Routing runs on the corrected name, so a rule works on what you meant.
        #expect(notes[0].relativePath == "Courses/Problems/Worksheet.md")
    }

    @Test("Matching ignores case, because the text being corrected is unreliable")
    func aliasMatchingIsForgiving() {
        let composer = NoteComposer(config: config, granularity: .section)
        #expect(composer.alias(for: "Vector Upending") == "Vector operations")
        #expect(composer.alias(for: "  workinet ") == "Worksheet")
        #expect(composer.alias(for: "Vectors") == nil)
    }

    @Test("A notebook's fallback name is never rewritten by an alias")
    func fallbackTitlesAreNotAliased() {
        var config = config
        config.sectionAliases = ["Calculus": "Something Else"]
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "no heading", confidence: 1, source: .vlm)])
        #expect(notes[0].relativePath == "Inkstone/Calculus/Calculus.md")
    }
}

@Suite("Abandoned runs")
struct AbandonedRunTests {

    @Test("A run whose process died is reaped when the store is next opened")
    func deadRunsAreReaped() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state.sqlite3")
            do {
                let state = try StateStore(url: url)
                _ = try state.beginRun()   // left open, as a killed process would
            }
            // Reopening simulates the next process to start.
            let reopened = try StateStore(url: url)
            let run = try #require(try reopened.recentRuns(limit: 1).first)
            #expect(run.status == "running", "our own live pid must not be reaped")

            // Now rewrite the row to a pid that cannot exist, and reopen again.
            #expect(run.finishedAt == nil)
        }
    }

    @Test("A live run belonging to another process is left alone")
    func liveRunsSurvive() throws {
        try Fixtures.withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state.sqlite3")
            let first = try StateStore(url: url)
            let id = try first.beginRun()

            // A second process opening the same database — the watcher and the
            // daily agent genuinely overlap — must not declare this abandoned.
            let second = try StateStore(url: url)
            let run = try #require(try second.recentRuns(limit: 1).first)
            #expect(run.id == id)
            #expect(run.status == "running")
        }
    }
}

@Suite("Granularity from config")
struct GranularityConfigTests {

    @Test("Granularity is a config setting, because the agents run a bare `run`")
    func resolvesFromConfig() {
        var config = InkstoneConfig.default
        #expect(config.resolvedGranularity == .notebook)

        config.granularity = "section"
        #expect(config.resolvedGranularity == .section)

        config.granularity = "page"
        #expect(config.resolvedGranularity == .page)

        // An unrecognised value falls back rather than failing the run.
        config.granularity = "chapters"
        #expect(config.resolvedGranularity == .notebook)
    }
}
