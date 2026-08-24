import Foundation
import Vision

public struct Check: Sendable {
    public enum Status: String, Sendable { case pass, warn, fail, info }
    public var status: Status
    public var title: String
    public var detail: String
    /// What the user should do about it, when there is something to do.
    public var remedy: String?

    public var symbol: String {
        switch status {
        case .pass: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .info: return "·"
        }
    }
}

/// Verifies that everything the pipeline depends on is actually in place.
///
/// Most Inkstone failures are setup failures — a backup that never arrived, a
/// vault path with a typo, a launch agent that silently unloaded — and they are
/// all invisible until notes stop appearing. `inkstone doctor` makes them
/// visible in one screen, with the fix next to each problem.
public struct Doctor: Sendable {

    public let config: InkstoneConfig
    public let configURL: URL

    public init(config: InkstoneConfig, configURL: URL = InkstoneConfig.defaultURL) {
        self.config = config
        self.configURL = configURL
    }

    public func run(state: StateStore? = nil) -> [Check] {
        var checks: [Check] = []
        checks.append(configCheck())
        checks.append(contentsOf: inboxChecks())
        checks.append(contentsOf: vaultChecks())
        checks.append(stateCheck(state))
        checks.append(visionCheck())
        checks.append(escalationCheck())
        checks.append(contentsOf: agentChecks())
        if let state { checks.append(lastRunCheck(state)) }
        return checks
    }

    // MARK: Config

    private func configCheck() -> Check {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return Check(status: .warn, title: "Config",
                         detail: "no config file; running on defaults",
                         remedy: "run `inkstone init` and edit \(configURL.path)")
        }
        return Check(status: .pass, title: "Config", detail: configURL.path, remedy: nil)
    }

    // MARK: Inbox

    private func inboxChecks() -> [Check] {
        let inbox = config.inboxURL
        var checks: [Check] = []

        guard FileManager.default.fileExists(atPath: inbox.path) else {
            return [Check(status: .fail, title: "Inbox", detail: "\(inbox.path) does not exist",
                          remedy: "point `inboxPath` at the folder your GoodNotes auto-backup "
                                  + "syncs into, then re-run — see docs/goodnotes-auto-backup.md")]
        }
        guard FileManager.default.isReadableFile(atPath: inbox.path) else {
            return [Check(status: .fail, title: "Inbox", detail: "\(inbox.path) is not readable",
                          remedy: "grant Full Disk Access to your terminal (and to Inkstone.app) "
                                  + "in System Settings → Privacy & Security")]
        }

        let pdfs = (try? Pipeline.findPDFs(in: inbox)) ?? []
        checks.append(Check(
            status: pdfs.isEmpty ? .warn : .pass,
            title: "Inbox",
            detail: pdfs.isEmpty
                ? "\(inbox.path) — no PDFs yet"
                : "\(inbox.path) — \(pdfs.count) PDF(s)",
            remedy: pdfs.isEmpty
                ? "check that GoodNotes Auto-Backup is on, set to PDF, and pointed at this folder"
                : nil))

        // A backup that has not changed in a fortnight usually means Auto-Backup
        // was switched off or the Drive account was signed out.
        if let newest = pdfs.compactMap({
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }).max() {
            let days = Int(Date().timeIntervalSince(newest) / 86_400)
            checks.append(Check(
                status: days > 14 ? .warn : .info,
                title: "Freshness",
                detail: "newest backup is \(days) day(s) old",
                remedy: days > 14
                    ? "open GoodNotes → Settings → Auto-Backup and confirm it is still enabled"
                    : nil))
        }

        if let provider = Self.cloudProvider(for: inbox) {
            checks.append(Check(status: .info, title: "Sync", detail: "inbox is inside \(provider)",
                                remedy: nil))
        } else {
            checks.append(Check(
                status: .warn, title: "Sync",
                detail: "inbox does not look like a cloud-synced folder",
                remedy: "Inkstone reads what the sync client puts on disk; if nothing syncs here, "
                        + "nothing will be transcribed"))
        }
        return checks
    }

    /// Names the sync client whose folder `url` lives under, if any.
    static func cloudProvider(for url: URL) -> String? {
        let path = url.path
        let markers: [(String, String)] = [
            ("CloudStorage/GoogleDrive", "Google Drive"),
            ("Google Drive", "Google Drive"),
            ("CloudStorage/Dropbox", "Dropbox"),
            ("Dropbox", "Dropbox"),
            ("Mobile Documents", "iCloud Drive"),
            ("CloudStorage/OneDrive", "OneDrive"),
            ("OneDrive", "OneDrive"),
        ]
        return markers.first { path.contains($0.0) }?.1
    }

    // MARK: Vault

    private func vaultChecks() -> [Check] {
        let vault = config.vaultURL
        guard FileManager.default.fileExists(atPath: vault.path) else {
            return [Check(status: .fail, title: "Vault", detail: "\(vault.path) does not exist",
                          remedy: "set `vaultPath` to your Obsidian vault root")]
        }
        var checks = [Check(
            status: FileManager.default.isWritableFile(atPath: vault.path) ? .pass : .fail,
            title: "Vault",
            detail: vault.path,
            remedy: FileManager.default.isWritableFile(atPath: vault.path)
                ? nil : "the vault folder is not writable")]

        let isObsidian = FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(".obsidian").path)
        checks.append(Check(
            status: isObsidian ? .info : .warn,
            title: "Obsidian",
            detail: isObsidian ? "vault has an .obsidian folder"
                               : "no .obsidian folder — is this really the vault root?",
            remedy: isObsidian ? nil : "point `vaultPath` at the folder you open in Obsidian"))
        return checks
    }

    // MARK: Everything else

    private func stateCheck(_ state: StateStore?) -> Check {
        guard let state else {
            return Check(status: .fail, title: "State", detail: "cannot open the state database",
                         remedy: "check permissions on \(StateStore.defaultURL.path)")
        }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: state.url.path)[.size] as? Int) ?? 0
        return Check(status: .pass, title: "State",
                     detail: "\(state.url.path) (\(size / 1024) KB)", remedy: nil)
    }

    private func visionCheck() -> Check {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let missing = config.recognitionLanguages.filter { !supported.contains($0) }
        guard missing.isEmpty else {
            return Check(status: .fail, title: "Vision",
                         detail: "unsupported language(s): \(missing.joined(separator: ", "))",
                         remedy: "supported here: \(supported.prefix(12).joined(separator: ", "))…")
        }
        return Check(status: .pass, title: "Vision",
                     detail: "accurate recognition for \(config.recognitionLanguages.joined(separator: ", "))",
                     remedy: nil)
    }

    private func escalationCheck() -> Check {
        guard config.resolvedEscalationMode != .off else {
            return Check(status: .info, title: "Escalation",
                         detail: "disabled — low-confidence pages are flagged, not sent anywhere",
                         remedy: nil)
        }
        let variable = config.resolvedKeyEnvVar
        let mode = config.resolvedEscalationMode.rawValue
        guard let key = ProcessInfo.processInfo.environment[variable], !key.isEmpty else {
            return Check(status: .fail, title: "Escalation",
                         detail: "\(mode), but \(variable) is not set",
                         remedy: "export \(variable) in your shell profile, or set it "
                                 + "in the launch agent's EnvironmentVariables")
        }
        return Check(status: .pass, title: "Escalation",
                     detail: "\(config.resolvedProvider.rawValue) \(config.resolvedModel), "
                             + "mode \(mode), threshold \(config.escalationThreshold)",
                     remedy: nil)
    }

    private func agentChecks() -> [Check] {
        [LaunchAgent.dailyLabel, LaunchAgent.watchLabel].map { label in
            let installed = LaunchAgent.isInstalled(label: label)
            let loaded = installed && LaunchAgent.isLoaded(label: label)
            return Check(
                status: !installed ? .info : (loaded ? .pass : .warn),
                title: "Agent \(label)",
                detail: !installed ? "not installed" : (loaded ? "loaded" : "installed but not loaded"),
                remedy: installed && !loaded ? "run `inkstone install-agent` again" : nil)
        }
    }

    private func lastRunCheck(_ state: StateStore) -> Check {
        guard let run = (try? state.recentRuns(limit: 1))?.first else {
            return Check(status: .info, title: "Last run", detail: "never run", remedy: nil)
        }
        let when = RelativeDateTimeFormatter().localizedString(for: run.startedAt, relativeTo: Date())
        return Check(
            status: run.status == "ok" ? .pass : .warn,
            title: "Last run",
            detail: "\(when) — \(run.status), \(run.pagesProcessed) page(s), "
                    + "\(run.notesWritten) note(s)",
            remedy: run.errorMessage)
    }
}
