import Foundation

/// User-facing configuration, loaded from `~/.config/inkstone/config.json`.
///
/// Every field has a defensible default so a fresh install runs with an empty
/// config file; `inkstone init` writes a fully populated one for editing.
public struct InkstoneConfig: Codable, Sendable {

    // MARK: Locations

    /// Folder the GoodNotes auto-backup lands in (a Google Drive sync folder).
    public var inboxPath: String

    /// Root of the Obsidian vault that receives transcribed notes.
    public var vaultPath: String

    /// Subfolder of the vault for generated notes, relative to `vaultPath`.
    public var notesSubfolder: String

    /// How pages are grouped into notes: `notebook`, `page`, or `section`.
    ///
    /// This lives in config rather than only on the command line because the
    /// launch agents run a bare `inkstone run`. A flag-only setting meant the
    /// scheduled runs silently used a different mode from the one you tested
    /// with, and produced a second, duplicate set of notes.
    public var granularity: String?

    /// Subfolder of the vault for cropped diagrams, relative to `vaultPath`.
    public var attachmentsSubfolder: String

    // MARK: Rendering

    /// Points-per-inch used when rasterising PDF pages for OCR and cropping.
    /// 300 is the sweet spot: Vision's accuracy plateaus above it and memory
    /// cost grows quadratically.
    public var renderDPI: Double

    // MARK: OCR

    /// Vision recognition languages, best-match first.
    public var recognitionLanguages: [String]

    /// Vision's language-model correction pass. Helps cursive, hurts formulas.
    public var usesLanguageCorrection: Bool

    /// Words fed to Vision as a custom vocabulary — names, jargon, project codes.
    public var customWords: [String]

    // MARK: Confidence gating (P2)

    /// A page whose OCR score falls below this escalates to the cloud VLM.
    public var escalationThreshold: Double

    /// Master switch for cloud escalation. When false, low-confidence pages are
    /// still written, flagged with `needs_review: true` in frontmatter.
    ///
    /// Kept for configs written before `escalationMode` existed; the mode wins
    /// when both are present.
    public var cloudEscalationEnabled: Bool

    /// Which pages go to the cloud model: `off`, `lowConfidence`, or `always`.
    ///
    /// Use `always` when Vision cannot read your hand at all. Gating relies on
    /// signals derived from an OCR pass that is wrong throughout, so it will
    /// wave through pages that are quietly garbage.
    public var escalationMode: String?

    /// Which service escalated pages go to: `openai` or `anthropic`.
    public var vlmProvider: String?

    /// Model used for escalated pages. Empty or absent takes the provider's
    /// default, so switching provider does not strand you on the other one's
    /// model name.
    public var vlmModel: String

    /// Env var holding the API key. Never store the key itself in config.
    /// Absent takes the provider's conventional variable.
    public var apiKeyEnvVar: String?

    /// File the key is read from when it is not in the environment. Absent uses
    /// `~/.config/inkstone/credentials`.
    ///
    /// This is what makes unattended runs work: launchd never sources a shell
    /// profile, so a key that only lives in `.zshrc` is invisible to the nightly
    /// agent.
    public var apiKeyFile: String?

    // MARK: Diagrams (P3)

    /// Minimum fraction of a page a diagram candidate must cover to be kept.
    /// Filters out ink specks, crossed-out words and stray underlines.
    public var minDiagramAreaFraction: Double

    /// Padding in pixels added around a detected diagram before cropping.
    public var diagramCropPadding: Int

    /// Master switch for diagram extraction.
    public var diagramExtractionEnabled: Bool

    // MARK: Routing (P4)

    /// Maps a source PDF's base name to a vault subfolder, e.g.
    /// `{"Physics 201": "Courses/Physics 201"}`. Unmatched notebooks land in
    /// `notesSubfolder/<Notebook Name>`.
    public var notebookRouting: [String: String]

    /// Emit `## Page N` headings. Off by default: page numbers come from the
    /// source PDF, and re-exporting or reordering a notebook renumbers them all,
    /// so they look like structure while carrying none.
    public var showPageNumbers: Bool

    /// Link the first mention of any other note's title as `[[Wikilink]]`.
    public var crossLink: Bool

    /// Tags added to the frontmatter of every generated note.
    public var defaultTags: [String]

    /// Corrects section names the recogniser gets wrong, e.g.
    /// `{"Workinet": "Worksheet"}`.
    ///
    /// Section names come from OCR, and a page that is almost entirely diagram
    /// gives any recogniser almost nothing to read. Renaming the note in
    /// Obsidian cannot fix it — the next run would recreate the misspelled note
    /// alongside the renamed one, because the path is derived from the source
    /// page every time. Correcting the name here fixes it at the source.
    public var sectionAliases: [String: String]

    /// Regular expressions matched against each transcribed line; anything that
    /// matches is dropped. Defaults to the GoodNotes free-tier watermark, which
    /// otherwise lands on every page of every note. Matching is case-insensitive
    /// and tolerant of OCR slips in the watermark itself.
    public var ignoreLinePatterns: [String]

    public static let `default` = InkstoneConfig(
        inboxPath: "~/Library/CloudStorage/GoogleDrive/My Drive/GoodNotes",
        vaultPath: "~/Obsidian/Vault",
        notesSubfolder: "Inkstone",
        granularity: nil,
        attachmentsSubfolder: "Inkstone/attachments",
        renderDPI: 300,
        recognitionLanguages: ["en-US"],
        usesLanguageCorrection: true,
        customWords: [],
        escalationThreshold: 0.55,
        cloudEscalationEnabled: false,
        escalationMode: nil,
        vlmProvider: nil,
        vlmModel: "",
        apiKeyEnvVar: nil,
        apiKeyFile: nil,
        minDiagramAreaFraction: 0.01,
        diagramCropPadding: 12,
        diagramExtractionEnabled: true,
        notebookRouting: [:],
        showPageNumbers: false,
        crossLink: true,
        defaultTags: ["inkstone", "handwritten"],
        sectionAliases: [:],
        ignoreLinePatterns: [#"^\s*m[a2o]d[eo]\s+w[il]th\s+g[o0]{2}dn[o0]tes\s*$"#]
    )
}

extension InkstoneConfig {

    /// `~/.config/inkstone/config.json`
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.config/inkstone/config.json").expandingTildeInPath)
    }

    /// Loads config from `url`, falling back to defaults when the file is absent.
    /// Missing keys inherit defaults, so old config files keep working when new
    /// fields are added.
    public static func load(from url: URL = InkstoneConfig.defaultURL) throws -> InkstoneConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        return try merging(defaults: .default, with: data)
    }

    public func write(to url: URL = InkstoneConfig.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Decodes `data` over `defaults` so a partial config file is legal.
    static func merging(defaults: InkstoneConfig, with data: Data) throws -> InkstoneConfig {
        let encoder = JSONEncoder()
        guard
            var base = try JSONSerialization.jsonObject(with: encoder.encode(defaults))
                as? [String: Any],
            let overlay = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw InkstoneError.config("config file is not a JSON object") }

        for (key, value) in overlay { base[key] = value }
        let merged = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(InkstoneConfig.self, from: merged)
    }

    // MARK: Resolved paths

    public var inboxURL: URL { Self.expand(inboxPath) }
    public var vaultURL: URL { Self.expand(vaultPath) }
    public var notesURL: URL { vaultURL.appendingPathComponent(notesSubfolder) }
    public var attachmentsURL: URL { vaultURL.appendingPathComponent(attachmentsSubfolder) }

    /// The note granularity in force. Defaults to one note per notebook.
    public var resolvedGranularity: NoteGranularity {
        granularity.flatMap { NoteGranularity(rawValue: $0) } ?? .notebook
    }

    /// The credentials file in force, or nil for the default location.
    public var credentialsURL: URL? {
        guard let apiKeyFile, !apiKeyFile.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return Self.expand(apiKeyFile)
    }

    /// The provider in force. Defaults to OpenAI.
    public var resolvedProvider: VLMProviderKind {
        vlmProvider.flatMap { VLMProviderKind(rawValue: $0.lowercased()) } ?? .openai
    }

    /// The model in force, falling back to the provider's default.
    public var resolvedModel: String {
        let trimmed = vlmModel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? resolvedProvider.defaultModel : trimmed
    }

    /// The environment variable the key is read from.
    public var resolvedKeyEnvVar: String {
        let trimmed = (apiKeyEnvVar ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? resolvedProvider.defaultKeyEnvVar : trimmed
    }

    /// The escalation mode actually in force, reconciling the newer
    /// `escalationMode` with the older `cloudEscalationEnabled` boolean.
    public var resolvedEscalationMode: EscalationMode {
        if let escalationMode, let mode = EscalationMode(rawValue: escalationMode) { return mode }
        return cloudEscalationEnabled ? .lowConfidence : .off
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }
}
