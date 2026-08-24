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
        if let access = fullDiskAccessCheck() { checks.append(access) }
        if let unattended = unattendedKeyCheck() { checks.append(unattended) }
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
        let resolution = Credentials.resolve(variable: variable, fileURL: config.credentialsURL)

        guard let key = resolution.value, !key.isEmpty else {
            return Check(status: .fail, title: "Escalation",
                         detail: "\(mode), but \(variable) is \(resolution.source)",
                         remedy: "run `inkstone set-key` to store it where both your shell "
                                 + "and the launchd agents can read it")
        }
        _ = key
        if let warning = resolution.permissionWarning {
            return Check(status: .warn, title: "Escalation",
                         detail: "\(config.resolvedProvider.rawValue) \(config.resolvedModel), mode \(mode)",
                         remedy: warning + " — run `chmod 600` on it")
        }
        return Check(status: .pass, title: "Escalation",
                     detail: "\(config.resolvedProvider.rawValue) \(config.resolvedModel), "
                             + "mode \(mode), key from \(resolution.source)",
                     remedy: nil)
    }

    /// Warns when the inbox sits somewhere a launchd agent cannot reach.
    ///
    /// This check exists because `doctor` normally runs from a terminal, which
    /// has permissions the scheduled agents do not. Everything looks green while
    /// the nightly run is failing — or worse, hanging — on a folder it is not
    /// allowed to read.
    private func fullDiskAccessCheck() -> Check? {
        let agentsInstalled = LaunchAgent.isInstalled(label: LaunchAgent.dailyLabel)
            || LaunchAgent.isInstalled(label: LaunchAgent.watchLabel)
        guard agentsInstalled else { return nil }

        // The paths macOS puts behind TCC. A launchd agent reaches none of them
        // without an explicit Full Disk Access grant.
        let protectedMarkers = ["/Library/CloudStorage", "/Documents", "/Desktop",
                                "/Downloads", "/Library/Mobile Documents"]
        let path = config.inboxURL.path
        guard protectedMarkers.contains(where: { path.contains($0) }) else { return nil }

        // Don't cry wolf. If the daily agent has actually completed a run, the
        // grant is in place and repeating the warning only teaches the user to
        // skim past doctor's output.
        if LaunchAgent.lastExitWasClean(label: LaunchAgent.dailyLabel) {
            return Check(status: .pass, title: "Full Disk Access",
                         detail: "granted — the daily agent last exited cleanly",
                         remedy: nil)
        }

        return Check(
            status: .warn, title: "Full Disk Access",
            detail: "the inbox is in a protected location; agents cannot read it by default",
            remedy: "System Settings → Privacy & Security → Full Disk Access → add "
                    + "Inkstone.app. Scheduled runs get no permission prompt of their own. "
                    + "Verify with: launchctl kickstart -k gui/$(id -u)/\(LaunchAgent.dailyLabel) "
                    + "then `inkstone status`.")
    }

    /// Warns when escalation depends on a key the launchd agents cannot see.
    private func unattendedKeyCheck() -> Check? {
        guard config.resolvedEscalationMode != .off else { return nil }
        let agentsInstalled = LaunchAgent.isInstalled(label: LaunchAgent.dailyLabel)
            || LaunchAgent.isInstalled(label: LaunchAgent.watchLabel)
        guard agentsInstalled else { return nil }

        let variable = config.resolvedKeyEnvVar
        let fromFile = Credentials.resolve(
            variable: variable, environment: [:], fileURL: config.credentialsURL).value
        guard fromFile == nil else { return nil }

        return Check(
            status: .warn, title: "Unattended key",
            detail: "\(variable) is not in the credentials file",
            remedy: "launchd does not read your shell profile, so the scheduled runs will "
                    + "silently stop escalating. Run `inkstone set-key` to fix it.")
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
