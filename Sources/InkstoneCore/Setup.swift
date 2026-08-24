import Foundation

/// Best-effort discovery of the two paths nobody wants to type.
///
/// A first run should not begin with the user hunting for the exact spelling of
/// their Google Drive folder or their vault root. Obsidian records its vaults in
/// a JSON file and macOS puts every cloud provider under one directory, so both
/// answers are usually already on disk.
public enum Setup {

    /// The Obsidian vault the user most recently had open, if Obsidian is installed.
    public static func detectVault() -> URL? {
        let registry = URL(fileURLWithPath: NSString(
            string: "~/Library/Application Support/obsidian/obsidian.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: registry),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = object["vaults"] as? [String: [String: Any]]
        else { return nil }

        let candidates = vaults.values.compactMap { entry -> (String, Double, Bool)? in
            guard let path = entry["path"] as? String else { return nil }
            return (path, entry["ts"] as? Double ?? 0, entry["open"] as? Bool ?? false)
        }
        // Prefer the vault that is open right now; otherwise the most recent.
        let best = candidates.max { a, b in
            a.2 != b.2 ? (!a.2 && b.2) : a.1 < b.1
        }
        guard let path = best?.0, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A plausible GoodNotes backup folder inside a cloud-synced directory.
    ///
    /// Looks for a folder whose name mentions GoodNotes first, and falls back to
    /// the root of the single cloud drive if there is exactly one — better to
    /// suggest a folder the user then narrows than to leave the field blank.
    public static func detectInbox() -> URL? {
        let fm = FileManager.default
        let roots = [
            "~/Library/CloudStorage",
            "~/Google Drive",
            "~/Dropbox",
            "~/Library/Mobile Documents/com~apple~CloudDocs",
        ].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .filter { fm.fileExists(atPath: $0.path) }

        var drives: [URL] = []
        for root in roots {
            let children = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            // ~/Library/CloudStorage holds one directory per provider account;
            // the other roots are already the drive itself.
            drives += root.lastPathComponent == "CloudStorage" ? children : [root]
        }

        for drive in drives {
            if let match = firstGoodNotesFolder(under: drive) { return match }
        }
        return drives.count == 1 ? drives.first : nil
    }

    /// Depth-limited search for a folder named after GoodNotes. Bounded because
    /// a cloud drive can be enormous and this runs during an interactive `init`.
    private static func firstGoodNotesFolder(under root: URL, maxDepth: Int = 3) -> URL? {
        let fm = FileManager.default
        var frontier = [(root, 0)]

        while !frontier.isEmpty {
            let (directory, depth) = frontier.removeFirst()
            guard depth < maxDepth else { continue }
            let children = (try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                if child.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
                    .contains("goodnotes") {
                    return child
                }
                frontier.append((child, depth + 1))
            }
        }
        return nil
    }

    /// A config pre-filled with whatever could be detected, plus a note about
    /// what is still a guess.
    public static func suggestedConfig() -> (config: InkstoneConfig, notes: [String]) {
        var config = InkstoneConfig.default
        var notes: [String] = []

        if let vault = detectVault() {
            config.vaultPath = shorten(vault.path)
            notes.append("Found your Obsidian vault: \(vault.path)")
        } else {
            notes.append("No Obsidian vault found — set `vaultPath` by hand.")
        }

        if let inbox = detectInbox() {
            config.inboxPath = shorten(inbox.path)
            notes.append("Using \(inbox.path) as the backup folder.")
            if !inbox.lastPathComponent.lowercased().contains("oodnotes") {
                notes.append("That is the drive root, not a GoodNotes folder — "
                             + "narrow `inboxPath` once Auto-Backup has run once.")
            }
        } else {
            notes.append("No cloud-sync folder found — set `inboxPath` after turning on "
                         + "GoodNotes Auto-Backup (see docs/goodnotes-auto-backup.md).")
        }
        return (config, notes)
    }

    /// Rewrites a path under the home directory back to `~/…` so the config file
    /// stays portable between accounts.
    static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
