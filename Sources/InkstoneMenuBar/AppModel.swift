import Foundation
import InkstoneCore
import SwiftUI

/// Observable state behind the menu bar item.
///
/// The app is a thin shell over `InkstoneCore` — the same pipeline the CLI runs,
/// the same SQLite state file — so what the menu shows is always the truth about
/// what the scheduled agent did, not a second, drifting copy of it.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: RunSummary?
    @Published private(set) var lastMessage: String = "Idle"
    @Published private(set) var problems: [Check] = []
    @Published private(set) var config: InkstoneConfig = .default
    @Published private(set) var loadFailure: String?

    private var state: StateStore?
    private var refreshTimer: Timer?

    init() {
        reload()
        // A minute is the right cadence: the daily agent and the watcher both
        // write to the same state file, and the user should see their results
        // without having to reopen the menu.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Loading

    func reload() {
        do {
            config = try InkstoneConfig.load()
            state = try StateStore()
            loadFailure = nil
        } catch {
            loadFailure = "\(error)"
        }
        refresh()
    }

    func refresh() {
        guard let state else { return }
        lastRun = try? state.recentRuns(limit: 1).first
        problems = Doctor(config: config).run(state: state)
            .filter { $0.status == .fail || $0.status == .warn }
    }

    // MARK: Actions

    func runNow(force: Bool = false) {
        guard !isRunning, let state else { return }
        isRunning = true
        lastMessage = "Running…"

        let config = self.config
        var options = PipelineOptions()
        options.reprocessAll = force

        Task.detached(priority: .utility) {
            let result = await Pipeline(config: config, state: state, options: options).run()
            await MainActor.run {
                self.isRunning = false
                self.lastMessage = result.summaryLine
                self.refresh()
                Notifier.post(
                    title: result.succeeded ? "Inkstone finished" : "Inkstone finished with errors",
                    body: result.summaryLine)
            }
        }
    }

    func openVault() { open(config.notesURL) }
    func openInbox() { open(config.inboxURL) }
    func openLogs() { open(Logger.defaultLogURL.deletingLastPathComponent()) }
    func openConfig() { NSWorkspace.shared.open(InkstoneConfig.defaultURL) }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Presentation

    var statusSymbol: String {
        if isRunning { return "pencil.and.outline" }
        if loadFailure != nil || problems.contains(where: { $0.status == .fail }) {
            return "exclamationmark.triangle"
        }
        return "text.book.closed"
    }

    var lastRunDescription: String {
        guard let lastRun else { return "Never run" }
        let when = RelativeDateTimeFormatter()
            .localizedString(for: lastRun.startedAt, relativeTo: Date())
        let detail = "\(lastRun.pagesProcessed) page\(lastRun.pagesProcessed == 1 ? "" : "s"), "
            + "\(lastRun.notesWritten) note\(lastRun.notesWritten == 1 ? "" : "s")"
        return lastRun.status == "ok" ? "\(when) — \(detail)" : "\(when) — failed"
    }

    var agentSummary: String {
        let daily = LaunchAgent.isLoaded(label: LaunchAgent.dailyLabel)
        let watcher = LaunchAgent.isLoaded(label: LaunchAgent.watchLabel)
        switch (daily, watcher) {
        case (true, true): return "Daily run and folder watcher active"
        case (true, false): return "Daily run active"
        case (false, true): return "Folder watcher active"
        case (false, false): return "No background agents installed"
        }
    }
}
