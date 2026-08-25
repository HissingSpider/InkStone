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
    /// True when part of this note came back unreliable from local recognition.
    ///
    /// A count of *which* pages used to live here, but page numbers are an
    /// artefact of the source PDF and a note can span several of them, so the
    /// only honest thing to report is whether any of it is suspect.
    public var needsReview: Bool
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
        let escalated = pages.contains { $0.source == .vlm }
        let needsReview = pages.contains { $0.needsReview && $0.source != .vlm }
        var used: Set<String> = []

        switch granularity {
        case .notebook:
            let body = pages
                .map { $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { config.showPageNumbers ? "## Page \($0.offset + 1)\n\n\($0.element)" : $0.element }
                .joined(separator: "\n\n---\n\n")
            return [makeNote(
                title: notebook, body: body, notebook: notebook, destination: folder,
                sourceURL: sourceURL, now: now, escalated: escalated,
                needsReview: needsReview, quality: Self.meanQuality(pages),
                isCategory: false, used: &used)]

        case .page:
            return pages.filter { !$0.isBlank }.map { page in
                makeNote(
                    title: "\(notebook) — p\(page.pageIndex + 1)",
                    body: page.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
                    notebook: notebook,
                    destination: folder.appending("/\(Self.safeFileName(notebook))"),
                    sourceURL: sourceURL, now: now,
                    escalated: page.source == .vlm,
                    needsReview: page.needsReview && page.source != .vlm,
                    quality: page.confidence, isCategory: false, used: &used)
            }

        case .section:
            return composeSections(notebook: notebook, folder: folder,
                                   sourceURL: sourceURL, pages: pages, now: now)
        }
    }

    // MARK: Sections

    /// Builds one note per heading, and turns any heading with sub-headings
    /// into an index that links to them.
    private func composeSections(
        notebook: String, folder: String, sourceURL: URL, pages: [PageOutput], now: Date
    ) -> [ComposedNote] {
        let combined = pages
            .map { $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")

        let continuations = config.continuationHeadings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        let tree = SectionParser.parse(combined)
            .dissolvingContinuations(matching: continuations)
        let nested = folder.isEmpty
            ? Self.safeFileName(notebook)
            : folder.appending("/\(Self.safeFileName(notebook))")
        let escalated = pages.contains { $0.source == .vlm }
        let needsReview = pages.contains { $0.needsReview && $0.source != .vlm }

        var notes: [ComposedNote] = []
        var used: Set<String> = []

        // Anything written before the first heading belongs to the notebook.
        if !tree.content.isEmpty {
            notes.append(makeNote(
                title: notebook, body: tree.content, notebook: notebook,
                destination: nested, sourceURL: sourceURL, now: now, escalated: escalated,
                needsReview: needsReview, quality: Self.meanQuality(pages),
                isCategory: false, used: &used))
        }

        for child in tree.children {
            emit(section: child, notebook: notebook, nested: nested, sourceURL: sourceURL,
                 now: now, escalated: escalated, needsReview: needsReview,
                 quality: Self.meanQuality(pages), into: &notes, used: &used)
        }

        // A notebook with no headings at all still has to produce something.
        if notes.isEmpty {
            notes.append(makeNote(
                title: notebook, body: combined, notebook: notebook,
                destination: nested, sourceURL: sourceURL, now: now, escalated: escalated,
                needsReview: needsReview, quality: Self.meanQuality(pages),
                isCategory: false, used: &used))
        }
        return notes
    }

    /// Emits `section` as a note, recursing while the heading level is still
    /// shallow enough to be worth its own file.
    private func emit(
        section: MarkdownSection, notebook: String, nested: String, sourceURL: URL,
        now: Date, escalated: Bool, needsReview: Bool, quality: Double,
        into notes: inout [ComposedNote], used: inout Set<String>
    ) {
        let rawTitle = section.title ?? notebook
        let title = alias(for: rawTitle) ?? rawTitle

        let splittableChildren = section.children.filter {
            $0.level <= config.sectionDepth && $0.title != nil
        }
        let inlineChildren = section.children.filter {
            !($0.level <= config.sectionDepth && $0.title != nil)
        }

        // Below the split depth, or with nothing worth splitting out, the whole
        // subtree stays in one note.
        guard section.level <= config.sectionDepth, !splittableChildren.isEmpty else {
            let body = Self.tidy(MarkdownSection(
                level: 0, title: nil, content: section.content,
                children: section.children).flattened())
            notes.append(makeNote(
                title: title, body: body, notebook: notebook,
                destination: routeIfMatched(title) ?? nested,
                sourceURL: sourceURL, now: now, escalated: escalated,
                needsReview: needsReview, quality: quality,
                isCategory: section.title != nil, used: &used))
            return
        }

        // A heading with sub-headings becomes an index. Its own prose stays —
        // that is the explanation of what the children have in common — and a
        // list of links follows.
        var childTitles: [String] = []
        for child in splittableChildren {
            let before = notes.count
            emit(section: child, notebook: notebook, nested: nested, sourceURL: sourceURL,
                 now: now, escalated: escalated, needsReview: needsReview,
                 quality: quality, into: &notes, used: &used)
            if notes.count > before { childTitles.append(notes[before].title) }
        }

        var parts: [String] = []
        let intro = MarkdownSection(level: 0, title: nil, content: section.content,
                                    children: inlineChildren).flattened()
        let tidied = Self.tidy(intro)
        if !tidied.isEmpty { parts.append(tidied) }
        if !childTitles.isEmpty {
            parts.append("## Contents\n"
                         + childTitles.map { "- [[\($0)]]" }.joined(separator: "\n"))
        }

        notes.append(makeNote(
            title: title, body: parts.joined(separator: "\n\n"), notebook: notebook,
            destination: routeIfMatched(title) ?? nested,
            sourceURL: sourceURL, now: now, escalated: escalated,
            needsReview: needsReview, quality: quality, isCategory: true, used: &used))
    }

    /// One note, routed and tagged.
    private func makeNote(
        title: String, body: String, notebook: String, destination: String, sourceURL: URL,
        now: Date, escalated: Bool, needsReview: Bool, quality: Double,
        isCategory: Bool, used: inout Set<String>
    ) -> ComposedNote {

        var frontmatter: [String: FrontmatterValue] = [
            "notebook": .string(notebook),
            "tags": .list(config.defaultTags + (isCategory ? [Self.slug(title)] : [])),
        ]
        if isCategory { frontmatter["category"] = .string(title) }
        if needsReview { frontmatter["needs_review"] = .bool(true) }
        frontmatter["updated"] = .date(now)

        var provenance = ["`\(sourceURL.lastPathComponent)`",
                          escalated ? config.resolvedModel : "vision",
                          Frontmatter.dayString(now)]
        if !escalated { provenance.append(String(format: "quality %.2f", quality)) }
        var footer = "> [!abstract]- Transcription\n> " + provenance.joined(separator: " · ")
        if needsReview {
            footer += "\n> Some of this was hard to read and may be wrong."
        }

        let name = Self.safeFileName(title)
        let path = destination.isEmpty ? "\(name).md" : "\(destination)/\(name).md"
        return ComposedNote(
            relativePath: Self.deduplicate(path, against: &used),
            body: body,
            frontmatter: frontmatter,
            footer: footer,
            needsReview: needsReview,
            title: title)
    }

    /// Strips page-separator rules stranded at either end of a section.
    static func tidy(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---"
            || first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "---"
            || last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Mean gate score across the pages that had content on them.
    static func meanQuality(_ pages: [PageOutput]) -> Double {
        let scores = pages.filter { !$0.isBlank }.map(\.confidence)
        return scores.isEmpty ? 1.0 : scores.reduce(0, +) / Double(scores.count)
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
