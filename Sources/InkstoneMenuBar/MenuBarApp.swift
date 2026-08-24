import InkstoneCore
import SwiftUI

@main
struct InkstoneMenuBarApp: App {

    @StateObject private var model = AppModel()

    init() {
        Notifier.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra("Inkstone", systemImage: model.statusSymbol) {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {

    @ObservedObject var model: AppModel

    var body: some View {
        if let failure = model.loadFailure {
            Text("Setup problem: \(failure)")
            Button("Open config…") { model.openConfig() }
            Divider()
        } else {
            Text(model.isRunning ? "Running…" : model.lastRunDescription)
            Text(model.lastMessage)
                .font(.caption)
            Divider()
        }

        Button(model.isRunning ? "Running…" : "Process now") { model.runNow() }
            .disabled(model.isRunning)
            .keyboardShortcut("r")

        Button("Re-transcribe everything…") { model.runNow(force: true) }
            .disabled(model.isRunning)

        Divider()

        if !model.problems.isEmpty {
            Menu("\(model.problems.count) thing\(model.problems.count == 1 ? "" : "s") to check") {
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Text("\(problem.symbol) \(problem.title): \(problem.detail)")
                }
            }
            Divider()
        }

        Text(model.agentSummary)
            .font(.caption)

        Button("Open notes folder") { model.openVault() }
        Button("Open backup folder") { model.openInbox() }
        Button("Open logs") { model.openLogs() }
        Button("Edit configuration…") { model.openConfig() }

        Divider()

        Button("Refresh") { model.reload() }
        Button("Quit Inkstone") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
