//
//  ShellSession.swift
//  Treemux
//

import AppKit
import Foundation
import Observation

// MARK: - Shell session lifecycle

enum ShellSessionLifecycle: Equatable {
    case idle
    case starting
    case running
    case exited

    var hasActiveProcess: Bool {
        switch self {
        case .starting, .running:
            return true
        case .idle, .exited:
            return false
        }
    }
}

// MARK: - Shell session

@MainActor
@Observable
final class ShellSession: Identifiable {
    let id: UUID
    let backendConfiguration: SessionBackendConfiguration

    var title: String
    var preferredWorkingDirectory: String
    var reportedWorkingDirectory: String?
    private(set) var lifecycle: ShellSessionLifecycle = .idle
    var exitCode: Int32?
    var pid: Int32?
    var rows: Int = 24
    var cols: Int = 80
    var surfaceStatus = TerminalSurfaceStatusSnapshot()
    private(set) var isReconnecting = false
    private(set) var reconnectError: String?

    /// Detected tmux session name, if the shell is running inside tmux.
    var detectedTmuxSession: String?

    @ObservationIgnored var onWorkspaceAction: ((TerminalWorkspaceAction) -> Void)?
    @ObservationIgnored var onFocus: (() -> Void)?

    private let surfaceController: ManagedTerminalSessionSurfaceController
    @ObservationIgnored private var launchConfiguration: TerminalLaunchConfiguration
    @ObservationIgnored private var isFocusedInWorkspace = false
    @ObservationIgnored private var reconnectBackend: SessionBackendConfiguration?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        backendConfiguration: SessionBackendConfiguration,
        preferredWorkingDirectory: String
    ) {
        var baseEnv = ShellSession.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        let launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )

        let surface = TerminalSurfaceFactory.make(
            preferred: .libghosttyPreferred,
            launchConfiguration: launchConfiguration
        )
        self.id = id
        self.backendConfiguration = backendConfiguration
        self.preferredWorkingDirectory = preferredWorkingDirectory
        self.launchConfiguration = launchConfiguration
        self.title = launchConfiguration.command.displayName
        self.surfaceController = surface
        configureSurfaceCallbacks()
    }

    init(
        id: UUID = UUID(),
        backendConfiguration: SessionBackendConfiguration,
        preferredWorkingDirectory: String,
        surfaceController: ManagedTerminalSessionSurfaceController
    ) {
        self.id = id
        self.backendConfiguration = backendConfiguration
        self.preferredWorkingDirectory = preferredWorkingDirectory
        var baseEnv = ShellSession.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        self.launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
        self.title = launchConfiguration.command.displayName
        self.surfaceController = surfaceController
        configureSurfaceCallbacks()
    }

    private func configureSurfaceCallbacks() {
        surfaceController.onResize = { [weak self] cols, rows in
            guard let self else { return }
            // Resize callbacks fire per-frame during window drags even when
            // the grid did not change; skip no-op publishes.
            let c = max(cols, 2)
            let r = max(rows, 2)
            if self.cols != c { self.cols = c }
            if self.rows != r { self.rows = r }
        }
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty, title != self.title else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
        }
        surfaceController.onWorkingDirectoryChange = { [weak self] directory in
            guard let self, directory != self.reportedWorkingDirectory else { return }
            self.reportedWorkingDirectory = directory
        }
        surfaceController.onFocus = { [weak self] in
            self?.onFocus?()
        }
        surfaceController.onStatusChange = { [weak self] status in
            guard let self, status != self.surfaceStatus else { return }
            self.surfaceStatus = status
        }

        surfaceController.onProcessExit = { [weak self] exitCode in
            guard let self else { return }
            self.applyProcessExit(exitCode)
        }
        if let ghosttySurface = surfaceController as? TreemuxGhosttyController {
            ghosttySurface.onWorkspaceAction = { [weak self] action in
                self?.onWorkspaceAction?(action)
            }
        }
    }

    // MARK: - Public interface

    var nsView: NSView {
        surfaceController.view
    }

    var effectiveWorkingDirectory: String {
        reportedWorkingDirectory ?? preferredWorkingDirectory
    }

    var backendLabel: String {
        backendConfiguration.displayName
    }

    var launchPath: String {
        launchConfiguration.command.executablePath
    }

    var launchArguments: [String] {
        launchConfiguration.command.arguments
    }

    var hasActiveProcess: Bool {
        lifecycle.hasActiveProcess
    }

    var isRunning: Bool {
        hasActiveProcess && needsQuitConfirmation
    }

    var needsQuitConfirmation: Bool {
        surfaceController.needsConfirmQuit
    }

    // MARK: - Session lifecycle

    func startIfNeeded() {
        guard lifecycle == .idle else { return }
        start()
    }

    func start() {
        var baseEnv = Self.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
        title = launchConfiguration.command.displayName

        exitCode = nil
        lifecycle = .starting
        surfaceController.updateLaunchConfiguration(launchConfiguration)
        surfaceController.startManagedSessionIfNeeded()
        surfaceController.setFocused(isFocusedInWorkspace)
        syncManagedProcessStateAfterLaunch()
    }

    func restart(in workingDirectory: String? = nil) {
        if let workingDirectory {
            preferredWorkingDirectory = workingDirectory
            reportedWorkingDirectory = nil
        }

        var baseEnv = Self.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
        surfaceController.updateLaunchConfiguration(launchConfiguration)
        exitCode = nil
        lifecycle = .starting
        surfaceController.restartManagedSession()
        surfaceController.setFocused(isFocusedInWorkspace)
        syncManagedProcessStateAfterLaunch()
    }

    func reconnect() {
        let backend = ReconnectBackendResolver.resolve(
            originalBackend: backendConfiguration,
            detectedTmuxSession: detectedTmuxSession
        )
        performReconnect(using: backend)
    }

    func retryReconnect() {
        guard let reconnectBackend, reconnectError != nil else { return }
        performReconnect(using: reconnectBackend)
    }

    func startShellAfterReconnectFailure() {
        guard reconnectError != nil else { return }
        performReconnect(using: ReconnectBackendResolver.shellFallback(for: backendConfiguration))
    }

    func updatePreferredWorkingDirectory(_ path: String, restartIfRunning: Bool) {
        preferredWorkingDirectory = path
        reportedWorkingDirectory = nil
        if restartIfRunning && hasActiveProcess {
            restart(in: path)
        }
    }

    func terminate() {
        surfaceController.terminateManagedSession()
        lifecycle = .exited
        pid = nil
        isReconnecting = false
    }

    // MARK: - Focus

    func focus() {
        surfaceController.focus()
    }

    func setFocused(_ isFocused: Bool) {
        isFocusedInWorkspace = isFocused
        surfaceController.setFocused(isFocused)
    }

    // MARK: - Terminal interaction

    func clear() {
        sendShellCommand("clear")
    }

    func beginSearch() {
        surfaceController.beginSearch(initialText: surfaceStatus.searchQuery)
    }

    func updateSearch(_ text: String) {
        surfaceController.updateSearch(text)
    }

    func searchNext() {
        surfaceController.searchNext()
    }

    func searchPrevious() {
        surfaceController.searchPrevious()
    }

    func endSearch() {
        surfaceController.endSearch()
    }

    func toggleReadOnly() {
        surfaceController.toggleReadOnly()
    }

    func insertText(_ text: String) {
        surfaceController.sendText(text)
    }

    func sendShellCommand(_ command: String) {
        surfaceController.sendText(command + "\n")
    }

    // MARK: - Snapshot

    func snapshot() -> PaneSnapshot {
        // Use the cached tmux session name resolved during runtime.
        // Filter out the generic "tmux" fallback — only save real session names.
        let tmuxSession: String? = {
            guard let name = detectedTmuxSession, name != "tmux" else { return nil }
            return name
        }()
        return PaneSnapshot(
            id: id,
            backend: backendConfiguration,
            workingDirectory: preferredWorkingDirectory,
            detectedTmuxSession: tmuxSession
        )
    }

    func isUsing(pathPrefix: String) -> Bool {
        let candidates = [effectiveWorkingDirectory, preferredWorkingDirectory]
        return candidates.contains { $0 == pathPrefix || $0.hasPrefix(pathPrefix + "/") }
    }

    // MARK: - Private helpers

    private static func defaultEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Treemux"
        environment["TERM_PROGRAM_VERSION"] = currentVersion()
        // Enable Ghostty shell integration features: title reporting lets us detect
        // foreground processes (e.g. tmux) from the terminal title set by preexec.
        // Note: "cursor" feature is intentionally omitted — it overrides cursor-style
        // set via Ghostty config. Cursor shape is controlled by AppSettings instead.
        environment["GHOSTTY_SHELL_FEATURES"] = "title,sudo"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        return environment
    }

    private static func currentVersion() -> String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "0.0.0"
    }

    private func syncManagedProcessStateAfterLaunch() {
        // Immediately set lifecycle based on surface state.
        lifecycle = surfaceController.isManagedSessionRunning ? .running : .starting
        // Resolve the shell PID asynchronously via process tree.
        resolveShellPID()
    }

    private func performReconnect(using backend: SessionBackendConfiguration) {
        guard !isReconnecting else { return }

        isReconnecting = true
        reconnectError = nil
        reconnectBackend = backend

        var baseEnvironment = Self.defaultEnvironment()
        baseEnvironment["TREEMUX_PANE_ID"] = id.uuidString
        launchConfiguration = backend.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnvironment
        )

        title = launchConfiguration.command.displayName
        reportedWorkingDirectory = nil
        detectedTmuxSession = nil
        surfaceStatus = TerminalSurfaceStatusSnapshot()
        exitCode = nil
        pid = nil
        lifecycle = .starting

        surfaceController.terminateManagedSession()
        surfaceController.updateLaunchConfiguration(launchConfiguration)
        surfaceController.startManagedSessionIfNeeded()
        surfaceController.setFocused(isFocusedInWorkspace)
        if isFocusedInWorkspace {
            surfaceController.focus()
        }
        syncManagedProcessStateAfterLaunch()
    }

    /// Discovers this pane's shell PID by searching the process tree for a descendant
    /// of the app process whose environment contains our TREEMUX_PANE_ID.
    private func resolveShellPID() {
        let paneID = id.uuidString
        let appPID = ProcessInfo.processInfo.processIdentifier
        Task { [weak self] in
            let maxAttempts = 10   // 10 × 200ms = 2s
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let shellPID = ProcessTree.findDescendant(
                    of: appPID, envKey: "TREEMUX_PANE_ID", envValue: paneID
                ) {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.pid = shellPID
                        if self.lifecycle == .starting {
                            self.lifecycle = .running
                        }
                        self.isReconnecting = false
                    }
                    return
                }
            }
            // Timeout — log and leave pid as nil. Not fatal; tmux detection
            // falls back to the placeholder filter in snapshot().
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.lifecycle == .starting {
                    self.lifecycle = .running
                }
                self.isReconnecting = false
            }
        }
    }

    private func applyProcessExit(_ exitCode: Int32?) {
        let wasReconnecting = isReconnecting
        self.exitCode = exitCode
        lifecycle = .exited
        pid = nil
        isReconnecting = false
        if wasReconnecting, case .tmuxAttach = reconnectBackend {
            reconnectError = String(localized: "Unable to reattach to the tmux session.")
        }
    }

    /// Detect if the shell is running inside tmux based on the terminal title.
    /// Title can be a command string from preexec (e.g. "tmux new -s hello"),
    /// a tmux status format like "[session-name] ...", or a tmux set-titles
    /// format like "session:0:bash - \"hostname\"".
    private func detectTmux(fromTitle title: String) {
        let lower = title.lowercased()

        // Pattern 1: tmux status bar format "[session-name] ..."
        if lower.hasPrefix("[") {
            if let closeBracket = title.firstIndex(of: "]") {
                let sessionName = String(title[title.index(after: title.startIndex)..<closeBracket])
                if !sessionName.isEmpty {
                    detectedTmuxSession = sessionName
                    return
                }
            }
        }

        // Pattern 2: preexec title showing the tmux command being run
        // e.g. "tmux", "tmux new -s hello", "tmux attach -t mysession"
        if lower.hasPrefix("tmux") {
            let args = title.split(separator: " ").map(String.init)
            if args.first?.lowercased() == "tmux" {
                if let sessionName = Self.parseTmuxSessionName(from: Array(args.dropFirst())) {
                    detectedTmuxSession = sessionName
                } else {
                    // Bare "tmux" or unrecognized args — resolve the session name after tmux starts.
                    detectedTmuxSession = "tmux"
                    resolveExactTmuxSession()
                }
                return
            }
        }

        // Pattern 3: tmux set-titles format "#S:#I:#W - \"#T\""
        // e.g. "13:0:bash - \"hostname\"", "dev:1:vim - \"file.txt\""
        // Enabled by injecting `tmux set-option -g set-titles on` on SSH launch.
        let parts = title.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.count == 3,
           let _ = Int(parts[1]),
           parts[2].contains(" - ") {
            let sessionName = parts[0]
            if !sessionName.isEmpty {
                detectedTmuxSession = sessionName
                return
            }
        }
    }

    /// Parses the session name from tmux command arguments.
    /// Handles: new -s <name>, new-session -s <name>, attach -t <name>, attach-session -t <name>, a -t <name>
    private static func parseTmuxSessionName(from args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let arg = args[i]
            // -s flag: session name for new/new-session
            if arg == "-s", i + 1 < args.count {
                return args[i + 1]
            }
            // -t flag: target session for attach/attach-session
            if arg == "-t", i + 1 < args.count {
                // Target may contain "session:window.pane", extract just session
                let target = args[i + 1]
                if let colonIdx = target.firstIndex(of: ":") {
                    return String(target[target.startIndex..<colonIdx])
                }
                return target
            }
            i += 1
        }
        return nil
    }

    /// When bare `tmux` is detected, resolve the exact session by matching the
    /// tmux client whose process environment carries this pane's `TREEMUX_PANE_ID`.
    ///
    /// This deliberately does NOT walk the process tree from the shell PID: the
    /// pane's login shell (`/bin/zsh` via `/usr/bin/login`) is a SIP-protected
    /// platform binary whose environment macOS hides from `KERN_PROCARGS2` for
    /// non-root callers, so the shell can never be located by `TREEMUX_PANE_ID`.
    /// The tmux client is a Homebrew binary whose environment *is* readable and
    /// inherits `TREEMUX_PANE_ID`, so we anchor on the client directly.
    private func resolveExactTmuxSession() {
        let paneID = id.uuidString
        Task { [weak self] in
            // Poll for our tmux client to register, then match it by env.
            for _ in 0..<15 {  // 15 × 300ms = 4.5s
                try? await Task.sleep(nanoseconds: 300_000_000)

                guard let result = await Self.queryTmuxClients() else { continue }
                let clients = ProcessTree.parseTmuxClientList(result)
                guard let sessionName = ProcessTree.tmuxSessionForPane(
                    paneID: paneID,
                    clients: clients,
                    env: ProcessTree.processEnvironment
                ) else { continue }

                await MainActor.run { [weak self] in
                    guard let self, self.detectedTmuxSession == "tmux" else { return }
                    self.detectedTmuxSession = sessionName
                }
                return
            }
        }
    }

    /// Queries tmux for all connected clients and their session names.
    private nonisolated static func queryTmuxClients() async -> String? {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "tmux list-clients -F '#{client_pid} #{session_name}'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
