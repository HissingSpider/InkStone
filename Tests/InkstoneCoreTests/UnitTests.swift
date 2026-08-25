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
            "category": .string("Notes"),
            "notebook": .string("Book"),
            "zzz_custom": .bool(true),
        ])
        let keys = block.split(separator: "\n")
            .filter { $0 != "---" }
            .map { String($0.split(separator: ":")[0]) }
        #expect(keys == ["category", "notebook", "tags", "zzz_custom"])
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
        #expect(notes[0].needsReview)
        #expect(notes[0].frontmatter["needs_review"] == .bool(true))
        #expect(notes[0].contents.contains("fine"))
        #expect(notes[0].contents.contains("murky"))
    }

    @Test("A page the gate cleared is not flagged, however low its raw score")
    func lowScoreAloneDoesNotFlag() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "ok", confidence: 0.10,
                               needsReview: false, source: .vision)])
        #expect(!notes[0].needsReview)
        #expect(notes[0].frontmatter["needs_review"] == nil)
    }

    @Test("An escalated page is never flagged for review")
    func escalatedPagesAreNotFlagged() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Recipes", sourceURL: URL(fileURLWithPath: "/tmp/Recipes.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "rescued", confidence: 1.0,
                               needsReview: true, source: .vlm)])
        #expect(!notes[0].needsReview)
        #expect(notes[0].frontmatter["needs_review"] == nil)
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
        // A blank page contributes nothing rather than a placeholder heading.
        #expect(!notes[0].contents.contains("## Page"))
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

    @Test("Writing inside a diagram is asked for as text, but not a description of it")
    func promptAsksForTextInsideDiagrams() {
        let prompt = VLMPrompt.user(pageNumber: 1, notebook: "Calculus",
                                    hasDiagrams: 1, visionDraft: nil)
        // A note that is only an image is not findable by its contents, which
        // is the whole point of transcribing.
        #expect(prompt.contains("labels, formulas"))
        #expect(prompt.contains("Do not describe the drawing itself"))
        // And the guard against the same phrase landing twice.
        #expect(prompt.contains("exactly once"))
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

@Suite("Section routing and naming")
struct SectionRoutingTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        config.notebookRouting = ["Vectors": "Courses/Linear Algebra"]
        return config
    }

    private func compose(_ markdown: String, config: InkstoneConfig? = nil,
                         notebook: String = "Current") -> [ComposedNote] {
        NoteComposer(config: config ?? self.config, granularity: .section).compose(
            notebook: notebook, sourceURL: URL(fileURLWithPath: "/tmp/\(notebook).pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: markdown, confidence: 1, source: .vlm)])
    }

    @Test("A routed section goes where the rule says; an unrouted one nests")
    func routingAppliesToSectionTitles() {
        let notes = compose("""
            ## Vectors

            length and direction

            ## Sprint Planning

            standup notes
            """)

        let vectors = try! #require(notes.first { $0.title == "Vectors" })
        #expect(vectors.relativePath == "Courses/Linear Algebra/Vectors.md")
        #expect(vectors.frontmatter["notebook"] == .string("Current"))

        // Unrouted sections nest under the notebook, so two notebooks cannot
        // both claim the same file name and overwrite each other every run.
        let sprint = try! #require(notes.first { $0.title == "Sprint Planning" })
        #expect(sprint.relativePath == "Inkstone/Current/Sprint Planning.md")
        #expect(sprint.frontmatter["tags"]
                == .list(["inkstone", "handwritten", "sprint-planning"]))
    }

    @Test("An empty destination means the vault root")
    func emptyDestinationIsTheRoot() {
        var rooted = config
        rooted.notebookRouting = ["Vectors": ""]
        let notes = compose("## Vectors\n\nbody", config: rooted)
        #expect(notes[0].relativePath == "Vectors.md")
    }

    @Test("A heading used twice does not overwrite itself")
    func duplicateHeadingsGetDistinctPaths() {
        let notes = compose("## Standup\n\nmonday\n\n## Standup\n\ntuesday")
        #expect(notes.count == 2)
        #expect(notes[0].relativePath != notes[1].relativePath)
        #expect(notes[1].relativePath.hasSuffix("Standup (2).md"))
    }

    @Test("An empty routing rule cannot swallow every section")
    func emptyPatternIsIgnored() {
        var greedy = config
        greedy.notebookRouting = ["": "Everything"]
        #expect(NoteComposer(config: greedy, granularity: .section)
                .routeIfMatched("Vectors") == nil)
    }

    @Test func fileNamesAreVaultSafe() {
        #expect(NoteComposer.safeFileName("A/B:C*D?") == "A-B-C-D-")
        #expect(NoteComposer.safeFileName("   ") == "Untitled")
        #expect(NoteComposer.safeFileName("Vector operations.") == "Vector operations")
        #expect(NoteComposer.safeFileName(".hidden") == "hidden")
        #expect(NoteComposer.safeFileName("...") == "Untitled")
        #expect(NoteComposer.slug("Physics 201 — Term 2") == "physics-201-term-2")
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

@Suite("Cross-linking")
struct LinkIndexTests {

    private var index: LinkIndex {
        LinkIndex(titles: ["Vectors", "Vector operations", "magnitude", "Economics", "Set"])
    }

    @Test("The first mention of another note becomes a wikilink")
    func linksFirstMention() {
        let out = index.linkify("We add vectors by coordinate.", excluding: "Scaling")
        #expect(out == "We add [[Vectors|vectors]] by coordinate.")
    }

    @Test("Casing is preserved with an alias rather than rewriting the sentence")
    func preservesOriginalCasing() {
        #expect(index.linkify("Economics is dismal.", excluding: "X")
                == "[[Economics]] is dismal.")
        #expect(index.linkify("economics is dismal.", excluding: "X")
                == "[[Economics|economics]] is dismal.")
    }

    @Test("Only the first mention is linked, so a note does not turn blue")
    func linksOnlyOnce() {
        let out = index.linkify("magnitude and magnitude and magnitude", excluding: "X")
        #expect(out == "[[magnitude]] and magnitude and magnitude")
    }

    @Test("The longest matching title wins")
    func prefersLongerTitles() {
        let out = index.linkify("See Vector operations for detail.", excluding: "X")
        #expect(out.contains("[[Vector operations]]"))
        #expect(!out.contains("[[Vectors|Vector]]"))
    }

    @Test("A note is never linked to itself")
    func neverLinksItself() {
        #expect(index.linkify("Vectors are useful.", excluding: "Vectors")
                == "Vectors are useful.")
    }

    @Test("Existing links, embeds, code, maths and headings are left alone")
    func respectsProtectedRegions() {
        #expect(index.linkify("[[Vectors]] already", excluding: "X") == "[[Vectors]] already")
        #expect(index.linkify("![[vectors.png]]", excluding: "X") == "![[vectors.png]]")
        #expect(index.linkify("`vectors`", excluding: "X") == "`vectors`")
        #expect(index.linkify("$vectors + 1$", excluding: "X") == "$vectors + 1$")
        #expect(index.linkify("## Vectors", excluding: "X") == "## Vectors")
        #expect(index.linkify("> Vectors in a callout", excluding: "X")
                == "> Vectors in a callout")
        #expect(index.linkify("```\nvectors\n```", excluding: "X") == "```\nvectors\n```")
    }

    @Test("Partial words are not linked")
    func matchesWholeWordsOnly() {
        #expect(index.linkify("vectorsalad", excluding: "X") == "vectorsalad")
        #expect(index.linkify("multivectors", excluding: "X") == "multivectors")
    }

    @Test("Very short titles are ignored, or every sentence would light up")
    func ignoresShortTitles() {
        // "Set" is three characters and was passed in, but never indexed.
        #expect(index.linkify("Set the value.", excluding: "X") == "Set the value.")
    }

    @Test("An empty index changes nothing")
    func emptyIndexIsANoOp() {
        #expect(LinkIndex().linkify("anything at all", excluding: "X") == "anything at all")
    }

    @Test("The vault's own notes are indexed, and win over ours")
    func scansTheVault() throws {
        try Fixtures.withTemporaryDirectory { directory in
            try "content".write(to: directory.appendingPathComponent("magnitude.md"),
                                atomically: true, encoding: .utf8)
            let nested = directory.appendingPathComponent("Sub")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "content".write(to: nested.appendingPathComponent("Eigenvalues.md"),
                                atomically: true, encoding: .utf8)

            let scanned = LinkIndex.scanningVault(at: directory)
            #expect(Set(scanned.titles) == ["magnitude", "Eigenvalues"])
        }
    }
}

@Suite("Note shape")
struct NoteShapeTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        return config
    }

    @Test("Properties stay small; provenance goes to a footer")
    func frontmatterIsMinimal() {
        let notes = NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 3, markdown: "## Vector operations\n\nbody",
                               confidence: 1, source: .vlm)])
        let note = notes[0]

        // Obsidian only parses properties at the top of the file, so what is up
        // there has to earn its place.
        #expect(note.frontmatter["category"] == .string("Vector operations"))
        #expect(note.frontmatter["notebook"] == .string("Calculus"))
        #expect(note.frontmatter["title"] == nil, "title duplicates the file name")
        #expect(note.frontmatter["source"] == nil)
        #expect(note.frontmatter["source_pages"] == nil)
        #expect(note.frontmatter["pages"] == nil)
        #expect(note.frontmatter["transcriber"] == nil)
        #expect(note.frontmatter["ocr"] == nil)
        #expect(note.frontmatter["quality"] == nil, "quality is meaningless for a VLM page")

        let contents = note.contents
        #expect(contents.contains("> [!abstract]- Transcription"))
        #expect(contents.contains("`Calculus.pdf`"))
        // And the footer really is at the bottom.
        let frontmatterEnd = contents.range(of: "\n---\n")!.upperBound
        #expect(contents.range(of: "[!abstract]")!.lowerBound > frontmatterEnd)
    }

    @Test("Page numbers are omitted by default, and pages separated by a rule")
    func noPageNumbersByDefault() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Log", sourceURL: URL(fileURLWithPath: "/tmp/Log.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "first", confidence: 1, source: .vlm),
                    PageOutput(pageIndex: 1, markdown: "second", confidence: 1, source: .vlm)])

        #expect(!notes[0].body.contains("## Page"))
        #expect(notes[0].body.contains("first\n\n---\n\nsecond"))
    }

    @Test("Page numbers come back when asked for")
    func pageNumbersAreOptIn() {
        var config = config
        config.showPageNumbers = true
        let notes = NoteComposer(config: config).compose(
            notebook: "Log", sourceURL: URL(fileURLWithPath: "/tmp/Log.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "first", confidence: 1, source: .vlm)])
        #expect(notes[0].body.contains("## Page 1"))
    }

    @Test("A hard-to-read page still says so, in both places it matters")
    func reviewFlagSurvivesTheSlimming() {
        let notes = NoteComposer(config: config).compose(
            notebook: "Log", sourceURL: URL(fileURLWithPath: "/tmp/Log.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: "murky", confidence: 0.4,
                               needsReview: true, source: .vision)])
        #expect(notes[0].frontmatter["needs_review"] == .bool(true))
        #expect(notes[0].contents.contains("hard to read"))
        #expect(notes[0].contents.contains("quality 0.40"))
    }
}

@Suite("Heading tree")
struct SectionParserTests {

    @Test func parsesNestedHeadings() {
        let tree = SectionParser.parse("""
            intro text

            ## Vector operations

            what these have in common

            ### Adding 2 vectors

            add coordinatewise

            ### Scaling vectors

            multiply each entry

            ## Parallel vectors

            scalar multiples
            """)

        #expect(tree.content == "intro text")
        #expect(tree.children.map(\.title) == ["Vector operations", "Parallel vectors"])

        let operations = tree.children[0]
        #expect(operations.content == "what these have in common")
        #expect(operations.children.map(\.title) == ["Adding 2 vectors", "Scaling vectors"])
        #expect(operations.children[0].content == "add coordinatewise")
    }

    @Test("A hash inside a code fence is not a heading")
    func ignoresFencedCode() {
        let tree = SectionParser.parse("## Real\n\n```\n# not a heading\n```\n")
        #expect(tree.children.count == 1)
        #expect(tree.children[0].content.contains("# not a heading"))
    }

    @Test func requiresSpaceAfterHashes() {
        #expect(SectionParser.heading(in: "#hashtag") == nil)
        #expect(SectionParser.heading(in: "####### too deep") == nil)
        #expect(SectionParser.heading(in: "## ") == nil)
        #expect(SectionParser.heading(in: "## Vectors")?.title == "Vectors")
    }

    @Test func flattensBackToMarkdown() {
        let markdown = "## A\n\nbody a\n\n### B\n\nbody b"
        #expect(SectionParser.parse(markdown).children[0].flattened() == markdown)
    }

    @Test func handlesNoHeadingsAtAll() {
        let tree = SectionParser.parse("just prose\n\nand more")
        #expect(tree.children.isEmpty)
        #expect(tree.content == "just prose\n\nand more")
    }
}

@Suite("Splitting into findable notes")
struct HierarchicalSectionTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        return config
    }

    private func compose(_ markdown: String, config: InkstoneConfig? = nil) -> [ComposedNote] {
        NoteComposer(config: config ?? self.config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: markdown, confidence: 1, source: .vlm)])
    }

    @Test("A topic with sub-topics becomes an index plus a note per sub-topic")
    func subTopicsBecomeTheirOwnNotes() {
        let notes = compose("""
            ## Vector operations

            things you can do to a vector

            ### Adding 2 vectors

            add coordinatewise

            ### Scaling vectors

            multiply each entry by c
            """)

        #expect(Set(notes.map(\.title))
                == ["Vector operations", "Adding 2 vectors", "Scaling vectors"])

        let index = try! #require(notes.first { $0.title == "Vector operations" })
        // The parent keeps its own prose — that is the explanation of what the
        // children have in common — and gains links to them.
        #expect(index.body.contains("things you can do to a vector"))
        #expect(index.body.contains("- [[Adding 2 vectors]]"))
        #expect(index.body.contains("- [[Scaling vectors]]"))
        // And it does not still contain the children's content.
        #expect(!index.body.contains("coordinatewise"))

        let child = try! #require(notes.first { $0.title == "Adding 2 vectors" })
        #expect(child.body.contains("add coordinatewise"))
        #expect(child.frontmatter["category"] == .string("Adding 2 vectors"))
    }

    @Test("Depth controls how finely a notebook is cut up")
    func depthIsConfigurable() {
        var shallow = config
        shallow.sectionDepth = 2
        let notes = compose("""
            ## Vector operations

            ### Adding 2 vectors

            add coordinatewise
            """, config: shallow)

        // At depth 2 the sub-topic stays inside its parent.
        #expect(notes.map(\.title) == ["Vector operations"])
        #expect(notes[0].body.contains("### Adding 2 vectors"))
        #expect(notes[0].body.contains("add coordinatewise"))
    }

    @Test("A topic with no sub-topics is left as one note, not made into an index")
    func leafTopicsAreNotIndexes() {
        let notes = compose("## Parallel vectors\n\nscalar multiples of each other")
        #expect(notes.map(\.title) == ["Parallel vectors"])
        #expect(!notes[0].body.contains("## Contents"))
        #expect(notes[0].body.contains("scalar multiples"))
    }

    @Test("Text before the first heading is kept under the notebook's name")
    func preambleIsNotLost() {
        let notes = compose("a cover page\n\n## Vectors\n\nlength and direction")
        #expect(notes.map(\.title).contains("Calculus"))
        #expect(try! #require(notes.first { $0.title == "Calculus" }).body
                .contains("a cover page"))
    }

    @Test("Aliases apply at any depth")
    func aliasesApplyToSubTopics() {
        var aliased = config
        aliased.sectionAliases = ["Vector upending": "Vector Notations"]
        let notes = compose("## Vector upending\n\ni, j, k", config: aliased)
        #expect(notes.map(\.title) == ["Vector Notations"])
    }
}

@Suite("Continuation headings")
struct ContinuationTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        return config
    }

    private func compose(_ markdown: String) -> [ComposedNote] {
        NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: markdown, confidence: 1, source: .vlm)])
    }

    @Test("A 'Continued' heading is dissolved, and hands its children to the real topic")
    func continuationsAreDissolved() {
        // Taken from a real page: the topic ran over, the next page was headed
        // "Continued", and the sub-topic that followed ended up filed under the
        // marker instead of under the topic it belongs to.
        let notes = compose("""
            ## Vector operations

            things you can do

            ### Adding 2 vectors

            add coordinatewise

            ## Continued

            leftover prose

            ### Scaling vectors

            multiply each entry
            """)

        #expect(!notes.contains { $0.title == "Continued" }, "no note should be named Continued")

        let index = try! #require(notes.first { $0.title == "Vector operations" })
        #expect(index.body.contains("- [[Adding 2 vectors]]"))
        #expect(index.body.contains("- [[Scaling vectors]]"), "the child was re-parented")
        // The marker's own prose is kept, not thrown away.
        #expect(index.body.contains("leftover prose"))
        #expect(notes.contains { $0.title == "Scaling vectors" })
    }

    @Test("Common spellings of the marker are all caught")
    func matchesTheUsualSpellings() {
        for marker in ["Continued", "continued", "cont.", "cont'd", "(continued)", "more"] {
            let notes = compose("## Real topic\n\nbody\n\n## \(marker)\n\nextra")
            #expect(!notes.contains { $0.title == marker }, "\(marker) should have dissolved")
        }
    }

    @Test("A continuation with nothing before it merges upward rather than vanishing")
    func leadingContinuationIsNotLost() {
        let notes = compose("## Continued\n\nsome orphaned prose")
        #expect(!notes.contains { $0.title == "Continued" })
        #expect(notes.contains { $0.body.contains("some orphaned prose") })
    }

    @Test("A real topic that merely starts with 'cont' is left alone")
    func doesNotOverMatch() {
        let notes = compose("## Contour integrals\n\nbody")
        #expect(notes.map(\.title) == ["Contour integrals"])
    }

    @Test("Page-separator rules do not survive at the edges of a note")
    func strayRulesAreTrimmed() {
        #expect(NoteComposer.tidy("---\n\nreal content\n\n---") == "real content")
        #expect(NoteComposer.tidy("a\n\n---\n\nb") == "a\n\n---\n\nb", "internal rules stay")
    }
}

@Suite("Model refusals are not transcriptions")
struct RefusalTests {

    @Test("A model explaining a blank page is recognised as blank")
    func detectsRefusals() {
        // Verbatim from a real run, which wrote this into the vault as a note.
        #expect(VLMPrompt.looksLikeRefusal("""
            I'm unable to transcribe the content of the page as no visible handwriting or \
            text is present in the image you provided. It appears to be a blank page \
            within a notebook.
            """))
        #expect(VLMPrompt.looksLikeRefusal("I'm sorry, I cannot transcribe this image."))
        #expect(VLMPrompt.looksLikeRefusal("This appears to be a blank page."))
    }

    @Test("A real transcription is never mistaken for a refusal")
    func doesNotSwallowRealNotes() {
        #expect(!VLMPrompt.looksLikeRefusal("## Vectors\n\nlength and direction"))
        #expect(!VLMPrompt.looksLikeRefusal("meeting notes about the blank page problem"))
        // Structure means someone wrote something, whatever words appear.
        #expect(!VLMPrompt.looksLikeRefusal("- I'm sorry I missed the meeting"))
        #expect(!VLMPrompt.looksLikeRefusal(""))
        // A long passage that merely contains the phrase is real content.
        #expect(!VLMPrompt.looksLikeRefusal(
            String(repeating: "no visible text here and much more besides. ", count: 12)))
    }
}

@Suite("Demoting false headings")
struct DemotedHeadingTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        config.ignoredHeadings = [#"^looks like$"#]
        return config
    }

    private func compose(_ markdown: String) -> [ComposedNote] {
        NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calls", sourceURL: URL(fileURLWithPath: "/tmp/Calls.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: markdown, confidence: 1, source: .vlm)])
    }

    @Test("The heading goes, the words stay")
    func demotesWithoutLosingText() {
        // Verbatim shape from a real page: the model emitted the phrase as both
        // a heading and the first line of the body.
        let notes = compose("""
            ## Looks like

            Looks like
            LUMIslate
            ADC quote

            ## Anna Only

            No Linkedin
            """)

        #expect(!notes.contains { $0.title == "Looks like" })
        #expect(notes.contains { $0.title == "Anna Only" })

        let kept = notes.map(\.body).joined(separator: "\n")
        #expect(kept.contains("LUMIslate"))
        // Not duplicated: the body already began with the phrase.
        #expect(kept.components(separatedBy: "Looks like").count - 1 == 1)
    }

    @Test("When the body does not repeat the phrase, it is put back")
    func restoresTheTextWhenAbsent() {
        let notes = compose("## Looks like\n\nLUMIslate only")
        let kept = notes.map(\.body).joined(separator: "\n")
        #expect(kept.contains("Looks like"))
        #expect(kept.contains("LUMIslate only"))
    }

    @Test("Headings not on the list are untouched")
    func leavesRealHeadingsAlone() {
        let notes = compose("## Real Topic\n\nbody")
        #expect(notes.map(\.title) == ["Real Topic"])
    }
}

@Suite("Note aliases")
struct NoteAliasTests {

    private var config: InkstoneConfig {
        var config = InkstoneConfig.default
        config.notesSubfolder = "Inkstone"
        // The page is headed "Computing length"; the user's own notes link to it
        // as [[magnitude]]. An alias resolves that without renaming the note to
        // something the page does not say.
        config.noteAliases = ["Computing length": ["magnitude"]]
        return config
    }

    private func compose(_ markdown: String) -> [ComposedNote] {
        NoteComposer(config: config, granularity: .section).compose(
            notebook: "Calculus", sourceURL: URL(fileURLWithPath: "/tmp/Calculus.pdf"),
            pages: [PageOutput(pageIndex: 0, markdown: markdown, confidence: 1, source: .vlm)])
    }

    @Test("An alias is emitted as Obsidian frontmatter, and the title is untouched")
    func aliasesReachFrontmatter() {
        let notes = compose("## Computing length\n\nthe formula")
        #expect(notes[0].title == "Computing length")
        #expect(notes[0].frontmatter["aliases"] == .list(["magnitude"]))
        #expect(notes[0].contents.contains("aliases: [magnitude]"))
    }

    @Test("Matching ignores case and stray whitespace")
    func aliasMatchingIsForgiving() {
        let composer = NoteComposer(config: config, granularity: .section)
        #expect(composer.aliasNames(for: "computing length") == ["magnitude"])
        #expect(composer.aliasNames(for: "  Computing Length ") == ["magnitude"])
        #expect(composer.aliasNames(for: "Scaling vectors") == nil)
    }

    @Test("Notes without an alias entry gain no aliases key")
    func noAliasesByDefault() {
        #expect(compose("## Scaling vectors\n\nbody")[0].frontmatter["aliases"] == nil)
    }
}

@Suite("Fuzzy alias matching")
struct FuzzyMatchTests {

    @Test("The same illegible heading, read twice, still matches its correction")
    func matchesObservedMisreadings() {
        // Every one of these pairs came from consecutive runs over the same page.
        #expect(FuzzyMatch.matches("Vector upending", "Vector uperting"))
        #expect(FuzzyMatch.matches("Anna Only", "Annual only"))
        #expect(FuzzyMatch.matches("Parallel Vectors", "Parallel vectors"))
    }

    @Test("Genuinely different titles do not collapse together")
    func doesNotOverMatch() {
        #expect(!FuzzyMatch.matches("Adding 2 vectors", "Scaling vectors"))
        #expect(!FuzzyMatch.matches("Economics", "Mechanics"))
        // Short strings are held to exact matching: one letter is the whole
        // difference between them.
        #expect(!FuzzyMatch.matches("add", "odd"))
        #expect(!FuzzyMatch.matches("i", "j"))
    }

    @Test func normalisationIgnoresCaseSpacingAndPunctuation() {
        #expect(FuzzyMatch.normalise("  Vector  Operations. ") == "vector operations")
        #expect(FuzzyMatch.matches("Vector Operations", "vector operations!"))
    }

    @Test func distanceIsCorrect() {
        #expect(FuzzyMatch.distance("kitten", "sitting") == 3)
        #expect(FuzzyMatch.distance("", "abc") == 3)
        #expect(FuzzyMatch.distance("same", "same") == 0)
    }

    @Test("A correction survives the recogniser changing its mind")
    func aliasesStickAcrossRuns() {
        var config = InkstoneConfig.default
        config.sectionAliases = ["Vector upending": "Vector Notations"]
        let composer = NoteComposer(config: config, granularity: .section)

        // The spelling the alias was written for.
        #expect(composer.alias(for: "Vector upending") == "Vector Notations")
        // And the spelling the next run produced.
        #expect(composer.alias(for: "Vector uperting") == "Vector Notations")
        // But not an unrelated heading.
        #expect(composer.alias(for: "Scaling vectors") == nil)
    }

    @Test("The closest alias wins when several are near")
    func picksTheNearestAlias() {
        var config = InkstoneConfig.default
        config.sectionAliases = ["Vector upending": "A", "Vector operations": "B"]
        let composer = NoteComposer(config: config, granularity: .section)
        #expect(composer.alias(for: "Vector uperting") == "A")
        #expect(composer.alias(for: "Vector operatons") == "B")
    }
}
