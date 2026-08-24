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
    public var cloudEscalationEnabled: Bool

    /// Anthropic model used for escalated pages.
    public var vlmModel: String

    /// Env var holding the Anthropic API key. Never store the key in config.
    public var apiKeyEnvVar: String

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

    /// Tags added to the frontmatter of every generated note.
    public var defaultTags: [String]

    public static let `default` = InkstoneConfig(
        inboxPath: "~/Library/CloudStorage/GoogleDrive/My Drive/GoodNotes",
        vaultPath: "~/Obsidian/Vault",
        notesSubfolder: "Inkstone",
        attachmentsSubfolder: "Inkstone/attachments",
        renderDPI: 300,
        recognitionLanguages: ["en-US"],
        usesLanguageCorrection: true,
        customWords: [],
        escalationThreshold: 0.55,
        cloudEscalationEnabled: false,
        vlmModel: "claude-opus-5",
        apiKeyEnvVar: "ANTHROPIC_API_KEY",
        minDiagramAreaFraction: 0.01,
        diagramCropPadding: 12,
        diagramExtractionEnabled: true,
        notebookRouting: [:],
        defaultTags: ["inkstone", "handwritten"]
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

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }
}
