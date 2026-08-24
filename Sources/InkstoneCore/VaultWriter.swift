import Foundation

public enum WriteOutcome: Sendable, Equatable {
    case created(URL)
    case updated(URL)
    /// Content matched what is already on disk; nothing was written.
    case unchanged(URL)
    /// A human edited the note (or it predates Inkstone). The transcription was
    /// written beside it instead, at `sidecar`.
    case protected(note: URL, sidecar: URL, reason: String)
    /// The note is pinned with `inkstone_lock: true`.
    case locked(URL)

    public var url: URL {
        switch self {
        case .created(let u), .updated(let u), .unchanged(let u), .locked(let u): return u
        case .protected(let note, _, _): return note
        }
    }

    public var wroteNote: Bool {
        switch self {
        case .created, .updated: return true
        default: return false
        }
    }
}

/// Writes notes into the Obsidian vault without ever destroying a human edit.
///
/// The contract is simple and absolute: Inkstone overwrites a file only when it
/// can prove, by hash, that the file is still byte-for-byte what Inkstone last
/// wrote. Anything else — an edit, an unrelated pre-existing file, a lock in
/// frontmatter — diverts the new transcription to a sidecar so the user can
/// diff and merge at their leisure. Losing a person's own annotations to an
/// automated re-run is the one failure this tool must never have.
public struct VaultWriter: Sendable {

    public let vaultURL: URL
    public let state: StateStore
    /// Overwrite even when the note looks edited. Only ever set from an
    /// explicit `--force` on the command line.
    public var force: Bool

    public init(vaultURL: URL, state: StateStore, force: Bool = false) {
        self.vaultURL = vaultURL
        self.state = state
        self.force = force
    }

    @discardableResult
    public func write(_ note: ComposedNote) throws -> WriteOutcome {
        let url = vaultURL.appendingPathComponent(note.relativePath)
        let key = note.relativePath
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = try? String(contentsOf: url, encoding: .utf8)

        // Nothing there yet: the simple, common path.
        guard let existing else {
            let contents = note.contents
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try state.upsertNote(NoteRecord(
                path: key, contentHash: Hashing.sha256(contents), writtenAt: Date()))
            return .created(url)
        }

        // An explicit lock wins over everything, including --force: it is the
        // user saying "this note is mine now".
        if let block = Frontmatter.split(existing).frontmatter,
           Frontmatter.value(of: "inkstone_lock", in: block) == "true" {
            return .locked(url)
        }

        // Carry the original creation date forward so re-runs do not make every
        // note look newly created.
        var note = note
        if let block = Frontmatter.split(existing).frontmatter,
           let created = Frontmatter.value(of: "created", in: block) {
            note.frontmatter["created"] = .string(created)
        }
        let contents = note.contents

        if existing == contents { return .unchanged(url) }

        let recorded = try state.noteRecord(path: key)?.contentHash
        let onDisk = Hashing.sha256(existing)
        let isOurs = recorded != nil && recorded == onDisk

        if isOurs || force {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try state.upsertNote(NoteRecord(
                path: key, contentHash: Hashing.sha256(contents), writtenAt: Date()))
            return .updated(url)
        }

        let reason = recorded == nil
            ? "note exists but was not written by Inkstone"
            : "note was edited after Inkstone last wrote it"
        let sidecar = try writeSidecar(contents, beside: url)
        return .protected(note: url, sidecar: sidecar, reason: reason)
    }

    /// Writes the rejected transcription next to the note as
    /// `Name.inkstone-new.md`, replacing any previous sidecar so they do not
    /// pile up over daily runs.
    private func writeSidecar(_ contents: String, beside url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let sidecar = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).inkstone-new.md")
        try contents.write(to: sidecar, atomically: true, encoding: .utf8)
        return sidecar
    }
}
