import Foundation
import InkstoneCore

let version = "1.0.0"

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

if arguments.has("verbose") { log.level = .debug }
if arguments.has("quiet") { log.level = .error }
if arguments.has("log-file") { log.attachFile() }

func loadConfig() throws -> (InkstoneConfig, URL) {
    let url = arguments.value("config").map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
    } ?? InkstoneConfig.defaultURL
    return (try InkstoneConfig.load(from: url), url)
}

func makeOptions(_ config: InkstoneConfig) -> PipelineOptions {
    var options = PipelineOptions()
    options.granularity = config.resolvedGranularity
    options.reprocessAll = arguments.has("all")
    options.rewrite = arguments.has("rewrite")
    options.force = arguments.has("force")
    options.dryRun = arguments.has("dry-run")
    options.only = arguments.list("file").map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
    }
    // An explicit flag still wins, for one-off experiments.
    if let granularity = arguments.value("granularity"),
       let parsed = NoteGranularity(rawValue: granularity) {
        options.granularity = parsed
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("inkstone: \(message)\n".utf8))
    exit(1)
}

// MARK: - Commands

func commandInit() throws {
    let (_, url) = try loadConfig()
    if FileManager.default.fileExists(atPath: url.path), !arguments.has("force") {
        Output.print("Config already exists at \(url.path)")
        Output.print(Output.dim("Pass --force to overwrite it with defaults."))
        return
    }
    let (suggested, notes) = Setup.suggestedConfig()
    try suggested.write(to: url)
    Output.print("Wrote \(Output.bold(url.path))")
    for note in notes { Output.print(Output.dim("  \(note)")) }
    Output.print("""

    Next:
      1. Edit that file — at minimum set \(Output.bold("inboxPath")) and \(Output.bold("vaultPath")).
      2. Turn on GoodNotes Auto-Backup (see docs/goodnotes-auto-backup.md).
      3. Run \(Output.bold("inkstone doctor")) to confirm everything lines up.
      4. Run \(Output.bold("inkstone run --dry-run")) to preview, then \(Output.bold("inkstone run")).
    """)
}

func commandRun() async throws {
    let (config, _) = try loadConfig()
    let state = try StateStore()
    let options = makeOptions(config)

    if options.dryRun { Output.print(Output.dim("dry run — nothing will be written")) }

    let pipeline = Pipeline(config: config, state: state, options: options)
    let result = await pipeline.run()

    if arguments.has("json") {
        Output.json([
            "documentsScanned": result.documentsScanned,
            "documentsChanged": result.documentsChanged,
            "pagesProcessed": result.pagesProcessed,
            "pagesCached": result.pagesCached,
            "pagesEscalated": result.pagesEscalated,
            "diagramsExtracted": result.diagramsExtracted,
            "notesWritten": result.notesWritten,
            "notesSkipped": result.notesSkipped,
            "errors": result.errors,
        ])
    } else {
        Output.print(result.succeeded
            ? Output.green(result.summaryLine)
            : Output.yellow(result.summaryLine))
        for outcome in result.outcomes {
            if case .locked(let note, let sidecar) = outcome, note != sidecar {
                Output.print(Output.dim("  locked: \(note.lastPathComponent) — new material "
                                        + "in \(sidecar.lastPathComponent)"))
            }
            if case .protected(let note, let sidecar, let reason) = outcome {
                Output.print(Output.yellow("  protected: \(note.lastPathComponent) — \(reason)"))
                Output.print(Output.dim("             transcription written to \(sidecar.path)"))
            }
        }
        for error in result.errors { Output.print(Output.red("  \(Output.oneLine(error))")) }
    }
    if !result.succeeded { exit(2) }
}

func commandWatch() async throws {
    let (config, _) = try loadConfig()
    let state = try StateStore()
    log.attachFile()

    // Wait for the inbox to become readable rather than exiting.
    //
    // The usual reason it is not is a missing Full Disk Access grant, which only
    // a human can fix. Exiting would hand the problem to launchd's KeepAlive,
    // which would respawn this process every thirty seconds forever, burning CPU
    // and filling the log with the same error. Waiting here means one quiet
    // process that starts working by itself the moment permission is granted.
    var delay: UInt64 = 30
    var complainedAbout: String?
    while true {
        do {
            try Pipeline.checkInboxAccess(config.inboxURL)
            if complainedAbout != nil { log.info("inbox is readable again; resuming") }
            break
        } catch {
            let message = "\(error)"
            // Log the first occurrence and any change, not every retry.
            if complainedAbout != message {
                log.error(message)
                log.info("retrying every \(delay)s until this is fixed")
                complainedAbout = message
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 900)
        }
    }

    // A resident process must not fall behind while it was not running, so do a
    // full pass on startup before settling into event-driven mode.
    let startup = Pipeline(config: config, state: state, options: makeOptions(config))
    _ = await startup.run()

    let quiet = Double(arguments.int("settle") ?? 20)
    let running = RunGate()

    let watcher = FolderWatcher(paths: [config.inboxURL], quietPeriod: quiet) { changed in
        Task {
            guard await running.begin() else {
                log.info("a run is already in flight; the change will be picked up next pass")
                return
            }
            defer { Task { await running.end() } }
            var options = makeOptions(config)
            options.only = changed
            _ = await Pipeline(config: config, state: state, options: options).run()
        }
    }
    try watcher.start()

    // Park forever; launchd owns this process's lifetime.
    //
    // Not dispatchMain(): this runs inside the async main's Task, on a
    // cooperative thread rather than the real main thread, so dispatchMain()
    // returns immediately instead of parking. The process then fell off the end
    // of main.swift and exited, launchd's KeepAlive restarted it, and the
    // watcher respawned every few seconds without ever watching anything.
    // FolderWatcher drives FSEvents from its own dispatch queue and needs no
    // run loop here — only for this task never to finish.
    while !Task.isCancelled {
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }
}

/// Serialises pipeline runs so a burst of file events cannot start two at once.
actor RunGate {
    private var active = false
    func begin() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }
    func end() { active = false }
}

func commandStatus() throws {
    let (config, configURL) = try loadConfig()
    let state = try StateStore()
    let runs = try state.recentRuns(limit: arguments.int("limit") ?? 5)

    if arguments.has("json") {
        let formatter = ISO8601DateFormatter()
        Output.json([
            "config": configURL.path,
            "inbox": config.inboxURL.path,
            "vault": config.vaultURL.path,
            "agents": [
                LaunchAgent.dailyLabel: LaunchAgent.isLoaded(label: LaunchAgent.dailyLabel),
                LaunchAgent.watchLabel: LaunchAgent.isLoaded(label: LaunchAgent.watchLabel),
            ],
            "runs": runs.map { run in
                [
                    "id": run.id,
                    "startedAt": formatter.string(from: run.startedAt),
                    "status": run.status,
                    "pagesProcessed": run.pagesProcessed,
                    "pagesEscalated": run.pagesEscalated,
                    "notesWritten": run.notesWritten,
                    "notesSkipped": run.notesSkipped,
                    "error": run.errorMessage ?? "",
                ]
            },
        ])
        return
    }

    Output.print(Output.bold("Inkstone \(version)"))
    Output.print("  config  \(configURL.path)")
    Output.print("  inbox   \(config.inboxURL.path)")
    Output.print("  vault   \(config.vaultURL.path)")
    Output.print("  daily   \(LaunchAgent.isLoaded(label: LaunchAgent.dailyLabel) ? "loaded" : "not loaded")")
    Output.print("  watcher \(LaunchAgent.isLoaded(label: LaunchAgent.watchLabel) ? "loaded" : "not loaded")")
    Output.print()

    guard !runs.isEmpty else {
        Output.print(Output.dim("No runs yet. Try `inkstone run --dry-run`."))
        return
    }
    Output.print(Output.bold("Recent runs"))
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d HH:mm"
    for run in runs {
        let status: String
        switch run.status {
        case "ok": status = Output.green("ok     ")
        case "running": status = Output.dim("running")
        case "interrupted": status = Output.yellow("stopped")
        default: status = Output.red("error  ")
        }
        var line = "  \(formatter.string(from: run.startedAt))  \(status)  "
            + "\(run.pagesProcessed) pages, \(run.notesWritten) notes"
        if run.pagesEscalated > 0 { line += ", \(run.pagesEscalated) escalated" }
        if run.notesSkipped > 0 { line += ", \(run.notesSkipped) protected" }
        Output.print(line)
        if let error = run.errorMessage {
            Output.print(Output.dim("       \(Output.oneLine(error))"))
        }
    }
}

func commandDoctor() throws {
    let (config, configURL) = try loadConfig()
    let state = try? StateStore()
    let checks = Doctor(config: config, configURL: configURL).run(state: state)

    if arguments.has("json") {
        Output.json(checks.map {
            ["status": $0.status.rawValue, "title": $0.title,
             "detail": $0.detail, "remedy": $0.remedy ?? ""]
        })
        return
    }

    for check in checks {
        let symbol: String
        switch check.status {
        case .pass: symbol = Output.green(check.symbol)
        case .warn: symbol = Output.yellow(check.symbol)
        case .fail: symbol = Output.red(check.symbol)
        case .info: symbol = Output.dim(check.symbol)
        }
        Output.print("\(symbol) \(Output.bold(check.title.padding(toLength: max(check.title.count, 16), withPad: " ", startingAt: 0)))  \(check.detail)")
        if let remedy = check.remedy {
            Output.print("  \(Output.dim("→ \(Output.oneLine(remedy))"))")
        }
    }

    let failures = checks.filter { $0.status == .fail }.count
    Output.print()
    Output.print(failures == 0
        ? Output.green("Ready.")
        : Output.red("\(failures) blocking problem(s) — fix those and re-run."))
    if failures > 0 { exit(1) }
}

func commandInstallAgent() throws {
    let (_, configURL) = try loadConfig()
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let configPath = arguments.has("config") ? configURL.path : nil

    let time = arguments.value("at") ?? "22:00"
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
        fail("--at expects HH:MM, got \(time)")
    }

    if !arguments.has("watch-only") {
        let url = try LaunchAgent.installDaily(
            executable: executable, hour: parts[0], minute: parts[1], configPath: configPath)
        Output.print("\(Output.green("✓")) daily agent at \(time) → \(url.path)")
    }
    if !arguments.has("daily-only") {
        let url = try LaunchAgent.installWatcher(executable: executable, configPath: configPath)
        Output.print("\(Output.green("✓")) folder watcher → \(url.path)")
    }
    Output.print(Output.dim("Logs: \(Logger.defaultLogURL.deletingLastPathComponent().path)"))
}

func commandUninstallAgent() throws {
    for label in [LaunchAgent.dailyLabel, LaunchAgent.watchLabel] {
        let removed = try LaunchAgent.uninstall(label: label)
        Output.print("\(removed ? Output.green("✓") : Output.dim("·")) \(label) "
                     + (removed ? "removed" : "was not installed"))
    }
}

func commandReset() throws {
    guard arguments.has("yes") else {
        Output.print("This forgets every cached page and note hash, so the next run "
                     + "re-transcribes everything.")
        Output.print("Notes already in your vault are not deleted, but re-runs will treat them "
                     + "as hand-edited and write sidecars.")
        Output.print("Re-run with \(Output.bold("--yes")) to proceed.")
        return
    }
    try StateStore().resetTranscriptionState()
    Output.print(Output.green("State cleared."))
}

func commandSetKey() throws {
    let (config, _) = try loadConfig()
    let variable = arguments.value("var") ?? config.resolvedKeyEnvVar
    let url = config.credentialsURL ?? Credentials.defaultURL

    // Read from stdin so the key never appears in an argument list, in `ps`
    // output, or in shell history — all of which `export KEY=...` exposes it to.
    let key: String
    if let piped = arguments.value("stdin"), piped == "-" {
        key = readLine() ?? ""
    } else if isatty(STDIN_FILENO) == 1 {
        Output.print("Paste your \(variable) (input is hidden), then press return:")
        key = Self_readSecret()
    } else {
        key = readLine() ?? ""
    }

    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { fail("no key given") }

    try Credentials.store(trimmed, as: variable, at: url)
    Output.print("\(Output.green("✓")) stored \(variable) in \(url.path) (mode 600)")
    Output.print("""

    Both your shell and the launchd agents read this file, so the key lives in \
    one place. To use it interactively too, replace the export line in your \
    ~/.zshrc with:

      source \(url.path)
    """)
}

/// Reads a line from the terminal with echo disabled.
func Self_readSecret() -> String {
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var quiet = original
    quiet.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        Output.print()
    }
    return readLine() ?? ""
}

func commandHelp() {
    Output.print("""
    \(Output.bold("inkstone")) \(version) — handwritten notebooks into an Obsidian vault

    \(Output.bold("USAGE"))
      inkstone <command> [options]

    \(Output.bold("COMMANDS"))
      init              Write a default config file
      doctor            Check the setup end to end and say what to fix
      run               Transcribe everything new in the inbox
      watch             Stay resident and transcribe as backups land
      status            Show configuration and recent runs
      install-agent     Install the launchd daily + watcher agents
      uninstall-agent   Remove them
      set-key           Store an API key where the launchd agents can read it
      reset             Forget cached hashes so the next run redoes everything
      version           Print the version

    \(Output.bold("RUN OPTIONS"))
      --all             Ignore caches; re-transcribe every page (costs API calls)
      --rewrite         Rebuild notes from cache; no re-transcription, no cost
      --force           Overwrite notes even if they look hand-edited
      --dry-run         Report what would happen; write nothing
      --file <path>     Only this PDF (repeatable)
      --granularity <notebook|page>
      --json            Machine-readable output

    \(Output.bold("GLOBAL OPTIONS"))
      --config <path>   Config file (default \(InkstoneConfig.defaultURL.path))
      --verbose         Debug logging
      --quiet           Errors only
      --log-file        Also write to \(Logger.defaultLogURL.path)

    \(Output.bold("INSTALL-AGENT OPTIONS"))
      --at HH:MM        Time of the daily run (default 22:00)
      --daily-only      Skip the folder watcher
      --watch-only      Skip the daily run
    """)
}

// MARK: - Dispatch

do {
    switch arguments.command {
    case "init": try commandInit()
    case "run": try await commandRun()
    case "watch": try await commandWatch()
    case "status": try commandStatus()
    case "doctor": try commandDoctor()
    case "install-agent": try commandInstallAgent()
    case "uninstall-agent": try commandUninstallAgent()
    case "set-key": try commandSetKey()
    case "reset": try commandReset()
    case "version", "--version": Output.print(version)
    case "", "help", "--help", "-h": commandHelp()
    default:
        FileHandle.standardError.write(Data("inkstone: unknown command '\(arguments.command)'\n".utf8))
        commandHelp()
        exit(64)
    }
} catch {
    fail("\(error)")
}
