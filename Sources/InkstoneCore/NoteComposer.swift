import Foundation

/// How transcribed pages are grouped into vault notes.
public enum NoteGranularity: String, Codable, Sendable {
    /// One note per source notebook, pages separated by headings. The default:
    /// it matches how people think about a notebook and keeps backlinks stable.
    case notebook
    /// One note per page. Better for very long notebooks and for people who
    /// link to individual pages.
    case page
}

/// One finished page, ready to be assembled into a note.
///
/// The pipeline produces these either from a fresh OCR pass or straight from
/// the state cache, so composing a note does not care which pages were actually
/// re-read this run.
public struct PageOutput: Sendable {
    public var pageIndex: Int
    /// Markdown for the page, diagram embeds already interleaved.
    public var markdown: String
    /// The confidence gate's blended quality score, not Vision's raw number.
    ///
    /// Vision reports high confidence on words it got wrong, so its own figure
    /// is the wrong thing to surface or to flag on.
    public var confidence: Double
    /// The gate's verdict, carried through rather than re-derived. Deriving it
    /// again from `confidence` was the bug that let visibly bad pages ship
    /// without a `needs_review` flag.
    public var needsReview: Bool
    public var source: TranscriptSource

    public init(pageIndex: Int, markdown: String, confidence: Double,
                needsReview: Bool = false, source: TranscriptSource) {
        self.pageIndex = pageIndex
        self.markdown = markdown
        self.confidence = confidence
        self.needsReview = needsReview
        self.source = source
    }

    public var isBlank: Bool {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A note ready to be written: where it goes and what is in it.
public struct ComposedNote: Sendable {
    public var relativePath: String
    public var body: String
    public var frontmatter: [String: FrontmatterValue]
    /// Pages that scored below the escalation threshold and were not rescued.
    public var lowConfidencePages: [Int]

    public var contents: String {
        Frontmatter.render(frontmatter) + "\n" + body + "\n"
    }
}

/// Assembles page transcripts into finished Obsidian notes.
public struct NoteComposer: Sendable {

    public var config: InkstoneConfig
    public var granularity: NoteGranularity
    private let builder = MarkdownBuilder()
    private let ignorePatterns: [NSRegularExpression]

    /// Placeholder the VLM is told to emit where a diagram belongs.
    public static let diagramPlaceholder = "[[INKSTONE-DIAGRAM]]"

    public init(config: InkstoneConfig, granularity: NoteGranularity = .notebook) {
        self.config = config
        self.granularity = granularity
        self.ignorePatterns = config.ignoreLinePatterns.compactMap {
            do {
                return try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            } catch {
                log.warn("ignoring malformed ignoreLinePattern \($0): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// True when a line is boilerplate the user never wrote — currently the
    /// GoodNotes free-tier watermark stamped onto every exported page.
    func isIgnored(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return ignorePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Builds every note for one source document.
    public func compose(
        notebook: String, sourceURL: URL, pages: [PageOutput], now: Date = Date()
    ) -> [ComposedNote] {
        let folder = route(notebook: notebook)
        switch granularity {
        case .notebook:
            return [composeSingle(notebook: notebook, folder: folder, sourceURL: sourceURL,
                                  pages: pages, now: now)]
        case .page:
            return pages.map { page in
                composeSingle(
                    notebook: "\(notebook) — p\(page.pageIndex + 1)",
                    folder: folder.appending("/\(Self.safeFileName(notebook))"),
                    sourceURL: sourceURL, pages: [page], now: now,
                    includePageHeadings: false)
            }
        }
    }

    private func composeSingle(
        notebook: String, folder: String, sourceURL: URL,
        pages: [PageOutput], now: Date, includePageHeadings: Bool = true
    ) -> ComposedNote {
        var sections: [String] = []
        var lowConfidence: [Int] = []
        var escalatedCount = 0

        for page in pages {
            if page.source == .vlm { escalatedCount += 1 }
            if page.needsReview && page.source != .vlm {
                lowConfidence.append(page.pageIndex + 1)
            }

            let body = page.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if includePageHeadings {
                var heading = "## Page \(page.pageIndex + 1)"
                if page.source == .vlm { heading += " ^vlm" }
                sections.append(body.isEmpty
                    ? "\(heading)\n\n*(blank page)*"
                    : "\(heading)\n\n\(body)")
            } else if !body.isEmpty {
                sections.append(body)
            }
        }

        let confidences = pages.filter { !$0.isBlank }.map(\.confidence)
        let meanConfidence = confidences.isEmpty
            ? 1.0 : confidences.reduce(0, +) / Double(confidences.count)

        var frontmatter: [String: FrontmatterValue] = [
            "title": .string(notebook),
            "source": .string(sourceURL.lastPathComponent),
            "pages": .int(pages.count),
            "transcriber": .string("inkstone"),
            "ocr": .string(escalatedCount == 0 ? "vision"
                           : (escalatedCount == pages.count ? "vlm" : "mixed")),
            "quality": .double((meanConfidence * 1000).rounded() / 1000),
            "created": .date(now),
            "updated": .date(now),
            "tags": .list(config.defaultTags),
        ]
        if !lowConfidence.isEmpty {
            frontmatter["needs_review"] = .bool(true)
            frontmatter["low_confidence_pages"] = .intList(lowConfidence)
        }

        return ComposedNote(
            relativePath: "\(folder)/\(Self.safeFileName(notebook)).md",
            body: sections.joined(separator: "\n\n"),
            frontmatter: frontmatter,
            lowConfidencePages: lowConfidence)
    }

    // MARK: Page body

    /// Renders one page, slotting diagram embeds into the text where they sit
    /// on the page rather than dumping them all at the bottom.
    public func pageBody(_ transcript: PageTranscript) -> String {
        if let vlm = transcript.vlmMarkdown {
            let kept = vlm.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !isIgnored(String($0).trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
            return Self.substitutePlaceholders(in: kept, with: transcript.diagrams)
        }

        let elements = builder.elements(for: transcript.lines.filter { !isIgnored($0.text) })
        let diagrams = transcript.diagrams.sorted { $0.anchorTopDownY < $1.anchorTopDownY }

        var merged: [String] = []
        var diagramIndex = 0

        for element in elements {
            // Emit every diagram whose top edge is above this line.
            while diagramIndex < diagrams.count,
                  diagrams[diagramIndex].anchorTopDownY <= element.topDownY {
                merged.append("")
                merged.append(diagrams[diagramIndex].wikilink)
                merged.append("")
                diagramIndex += 1
            }
            merged.append(element.text)
        }
        while diagramIndex < diagrams.count {
            merged.append("")
            merged.append(diagrams[diagramIndex].wikilink)
            diagramIndex += 1
        }

        return MarkdownBuilder.collapseBlankRuns(merged).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the VLM's ordered placeholders with real embeds, appending any
    /// diagram the model did not account for so nothing is silently dropped.
    static func substitutePlaceholders(in markdown: String, with diagrams: [DiagramCrop]) -> String {
        var result = markdown
        var used = 0
        while let range = result.range(of: diagramPlaceholder) {
            let replacement = used < diagrams.count ? diagrams[used].wikilink : ""
            result.replaceSubrange(range, with: replacement)
            used += 1
        }
        let leftovers = diagrams.dropFirst(min(used, diagrams.count))
        if !leftovers.isEmpty {
            result += "\n\n" + leftovers.map(\.wikilink).joined(separator: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Routing

    /// Vault-relative folder for `notebook`, honouring explicit routing rules.
    ///
    /// Matching is case-insensitive and accepts a prefix, so a rule for
    /// "Physics 201" catches "Physics 201 - Term 2.pdf" too.
    public func route(notebook: String) -> String {
        let needle = notebook.lowercased()
        for (pattern, destination) in config.notebookRouting
        where needle == pattern.lowercased() || needle.hasPrefix(pattern.lowercased()) {
            return destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return config.notesSubfolder
    }

    // MARK: Names

    /// A file name safe on APFS and in Obsidian wikilinks.
    public static func safeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(
            of: " +", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "Untitled" : String(collapsed.prefix(120))
    }

    /// Lowercase, hyphenated identifier used for attachment file names.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return lowered.isEmpty ? "note" : String(lowered.prefix(60))
    }
}
