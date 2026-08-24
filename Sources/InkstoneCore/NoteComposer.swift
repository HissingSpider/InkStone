import Foundation

/// How transcribed pages are grouped into vault notes.
public enum NoteGranularity: String, Codable, Sendable {
    /// One note per source notebook, pages separated by headings. The default:
    /// it matches how people think about a notebook and keeps backlinks stable.
    case notebook
    /// One note per page. Better for very long notebooks and for people who
    /// link to individual pages.
    case page
    /// One note per section, where a section starts at a page whose first line
    /// is a heading.
    ///
    /// This is the mode for people whose notebook count is capped and who
    /// therefore keep several subjects in one book. It turns a catch-all
    /// notebook back into properly named, properly routed, individually
    /// categorised notes.
    case section
}

/// A run of consecutive pages sharing one heading.
struct Section {
    var title: String
    var pages: [PageOutput]
    /// True when the title came from a real heading rather than a fallback to
    /// the notebook name, which is what makes it worth routing and tagging on.
    var isExplicit: Bool
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
    /// Provenance, rendered as a collapsed callout beneath the body.
    ///
    /// Obsidian only parses properties at the very top of a file, so the block
    /// up there has to stay small and useful. Everything that is merely a record
    /// of how the note was made belongs out of the way at the bottom.
    public var footer: String?
    /// Pages that scored below the escalation threshold and were not rescued.
    public var lowConfidencePages: [Int]
    /// The note's own name, so cross-linking can avoid linking it to itself.
    public var title: String = ""

    public var contents: String {
        var text = Frontmatter.render(frontmatter) + "\n" + body + "\n"
        if let footer { text += "\n---\n\n" + footer + "\n" }
        return text
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

        case .section:
            var used: Set<String> = []
            return Self.sections(in: pages, fallbackTitle: notebook).map { rawSection in
                var section = rawSection
                if section.isExplicit, let corrected = alias(for: section.title) {
                    section.title = corrected
                }
                // An explicit heading may have its own routing rule; that is the
                // point of the mode, so it wins over the notebook's rule. Without
                // one, notes nest under the notebook so two books cannot both
                // claim "Vectors.md" and overwrite each other every run.
                let destination = section.isExplicit
                    ? routeIfMatched(section.title)
                        ?? folder.appending("/\(Self.safeFileName(notebook))")
                    : folder.appending("/\(Self.safeFileName(notebook))")

                var note = composeSingle(
                    notebook: section.title, folder: destination, sourceURL: sourceURL,
                    pages: section.pages, now: now,
                    includePageHeadings: section.pages.count > 1)

                note.frontmatter["notebook"] = .string(notebook)
                if section.isExplicit {
                    note.frontmatter["category"] = .string(section.title)
                    // Tagging as well as a field: a field is queryable, a tag is
                    // clickable, and Obsidian users reach for both.
                    note.frontmatter["tags"] = .list(config.defaultTags + [Self.slug(section.title)])
                }
                note.relativePath = Self.deduplicate(note.relativePath, against: &used)
                return note
            }
        }
    }

    // MARK: Sections

    /// Splits `pages` into runs that each begin with a heading page.
    ///
    /// Pages before the first heading become a leading section named after the
    /// notebook, so nothing is ever dropped for want of a title.
    static func sections(in pages: [PageOutput], fallbackTitle: String) -> [Section] {
        var sections: [Section] = []

        for page in pages {
            if let title = sectionTitle(of: page.markdown) {
                sections.append(Section(title: title, pages: [page], isExplicit: true))
            } else if sections.isEmpty {
                sections.append(Section(title: fallbackTitle, pages: [page], isExplicit: false))
            } else {
                sections[sections.count - 1].pages.append(page)
            }
        }
        return sections
    }

    /// The configured correction for an OCR'd section name, if there is one.
    /// Matching ignores case and surrounding whitespace, because the thing being
    /// corrected is by definition unreliable text.
    func alias(for title: String) -> String? {
        let needle = title.lowercased().trimmingCharacters(in: .whitespaces)
        for (wrong, right) in config.sectionAliases
        where wrong.lowercased().trimmingCharacters(in: .whitespaces) == needle {
            return right
        }
        return nil
    }

    /// The heading a page opens with, if it opens with one.
    ///
    /// Reads the finished markdown rather than the raw OCR lines, which means it
    /// works identically for locally recognised pages and for cloud-transcribed
    /// ones, and costs nothing for a cached page because the markdown is already
    /// stored.
    static func sectionTitle(of markdown: String) -> String? {
        guard let first = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }

        let line = first.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("#") else { return nil }

        let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)

        // A title is short and has words in it. These filters keep a long
        // sentence that merely happens to be written large, or a smear of OCR
        // punctuation, from becoming a note name.
        guard title.count >= 3, title.count <= 60 else { return nil }
        guard title.split(separator: " ").count <= 6 else { return nil }
        guard title.contains(where: \.isLetter) else { return nil }
        return title
    }

    /// Ensures each note in a run gets its own path, since a notebook can
    /// legitimately carry the same heading twice.
    static func deduplicate(_ path: String, against used: inout Set<String>) -> String {
        guard used.contains(path) else {
            used.insert(path)
            return path
        }
        let base = String(path.dropLast(3))
        for suffix in 2...99 {
            let candidate = "\(base) (\(suffix)).md"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
        }
        return path
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
            guard !body.isEmpty else { continue }

            // Page numbers are an artefact of the source PDF, not of the notes.
            // Reordering or re-exporting a notebook renumbers everything, so a
            // heading built from them is worse than no heading: it looks like
            // structure and is really just noise.
            sections.append(includePageHeadings && config.showPageNumbers
                ? "## Page \(page.pageIndex + 1)\n\n\(body)"
                : body)
        }

        let confidences = pages.filter { !$0.isBlank }.map(\.confidence)
        let meanConfidence = confidences.isEmpty
            ? 1.0 : confidences.reduce(0, +) / Double(confidences.count)
        let method = escalatedCount == 0 ? "vision"
            : (escalatedCount == pages.count ? config.resolvedModel : "mixed")

        // The small, queryable block at the top.
        var frontmatter: [String: FrontmatterValue] = [
            "notebook": .string(notebook),
            "tags": .list(config.defaultTags),
        ]
        if !lowConfidence.isEmpty {
            frontmatter["needs_review"] = .bool(true)
        }
        frontmatter["updated"] = .date(now)

        // The record of how it was made, tucked underneath.
        var provenance = ["`\(sourceURL.lastPathComponent)`", method,
                          Frontmatter.dayString(now)]
        if method == "vision" {
            provenance.append(String(format: "quality %.2f", meanConfidence))
        }
        var footer = "> [!abstract]- Transcription\n> " + provenance.joined(separator: " · ")
        if !lowConfidence.isEmpty {
            footer += "\n> Some of this page was hard to read and may be wrong."
        }

        return ComposedNote(
            relativePath: "\(folder)/\(Self.safeFileName(notebook)).md",
            body: sections.joined(separator: "\n\n---\n\n"),
            frontmatter: frontmatter,
            footer: footer,
            lowConfidencePages: lowConfidence,
            title: notebook)
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
        routeIfMatched(notebook) ?? config.notesSubfolder
    }

    /// The configured destination for `name`, or nil when no rule matches.
    ///
    /// Separate from `route` because a section title that matches no rule must
    /// fall back to nesting under its notebook, not to the vault's default
    /// folder — otherwise every unrouted section from every notebook would pile
    /// into one directory.
    func routeIfMatched(_ name: String) -> String? {
        let needle = name.lowercased()
        for (pattern, destination) in config.notebookRouting.sorted(by: { $0.key > $1.key })
        where !pattern.isEmpty
            && (needle == pattern.lowercased() || needle.hasPrefix(pattern.lowercased())) {
            return destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }

    // MARK: Names

    /// A file name safe on APFS and in Obsidian wikilinks.
    public static func safeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(
            of: " +", with: " ", options: .regularExpression)
        // Trailing dots would give "Vector operations..md", and a leading dot
        // would hide the note from Finder and from Obsidian's file list.
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    /// Lowercase, hyphenated identifier used for attachment file names.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return lowered.isEmpty ? "note" : String(lowered.prefix(60))
    }
}
