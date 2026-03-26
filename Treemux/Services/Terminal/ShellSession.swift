//
//  ShellSession.swift
//  Treemux
//

import AppKit
import Combine
import Foundation

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
final class ShellSession: ObservableObject, Identifiable {
    let id: UUID
    let backendConfiguration: SessionBackendConfiguration

    @Published var title: String
    @Published var preferredWorkingDirectory: String
    @Published var reportedWorkingDirectory: String?
    @Published private(set) var lifecycle: ShellSessionLifecycle = .idle
    @Published var exitCode: Int32?
    @Published var pid: Int32?
    @Published var rows: Int = 24
    @Published var cols: Int = 80
    @Published var surfaceStatus = TerminalSurfaceStatusSnapshot()

    /// Detected tmux session name, if the shell is running inside tmux.
    @Published var detectedTmuxSession: String?

    /// Detected AI tool running in this pane.
    @Published var detectedAITool: AIToolDetection?

    var onWorkspaceAction: ((TerminalWorkspaceAction) -> Void)?
    var onFocus: (() -> Void)?

    private let surfaceController: ManagedTerminalSessionSurfaceController
    private var launchConfiguration: TerminalLaunchConfiguration
    private var isFocusedInWorkspace = false

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
            self.cols = max(cols, 2)
            self.rows = max(rows, 2)
        }
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
            self.detectAITool(fromTitle: title)
        }
        surfaceController.onWorkingDirectoryChange = { [weak self] directory in
            self?.reportedWorkingDirectory = directory
        }
        surfaceController.onFocus = { [weak self] in
            self?.onFocus?()
        }
        surfaceController.onStatusChange = { [weak self] status in
            self?.surfaceStatus = status
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
        environment["GHOSTTY_SHELL_FEATURES"] = "cursor,title,sudo"
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
            }
        }
    }

    private func applyProcessExit(_ exitCode: Int32?) {
        self.exitCode = exitCode
        lifecycle = .exited
        pid = nil
    }

    /// Detect if an AI tool is running based on the terminal title.
    private func detectAITool(fromTitle title: String) {
        // Extract the likely process name from the title
        let processName = title.components(separatedBy: " ").first ?? title
        if let kind = AIToolKind.detect(processName: processName) {
            detectedAITool = AIToolDetection(kind: kind, isRunning: true, processName: processName)
        } else if detectedAITool != nil {
            // Only clear if the previously detected tool is no longer in the title
            let lower = title.lowercased()
            if !lower.contains("claude") && !lower.contains("codex") {
                detectedAITool = nil
            }
        }
    }

    /// Detect if the shell is running inside tmux based on the terminal title.
    /// Title can be a command string from preexec (e.g. "tmux new -s hello")
    /// or a tmux status format like "[session-name] ...".
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
        guard lower.hasPrefix("tmux") else { return }

        let args = title.split(separator: " ").map(String.init)
        guard args.first?.lowercased() == "tmux" else { return }

        // Parse -s (new session name) or -t (target session) from the arguments.
        if let sessionName = Self.parseTmuxSessionName(from: Array(args.dropFirst())) {
            detectedTmuxSession = sessionName
        } else {
            // Bare "tmux" or unrecognized args — resolve the session name after tmux starts.
            detectedTmuxSession = "tmux"
            resolveExactTmuxSession()
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

    /// When bare `tmux` is detected, resolve the exact session by finding the tmux
    /// client process that is a descendant of this pane's shell in the process tree.
    private func resolveExactTmuxSession() {
        Task { [weak self] in
            // Step 1: Wait for shell PID to be resolved.
            var shellPID: pid_t?
            for _ in 0..<15 {  // 15 × 200ms = 3s
                try? await Task.sleep(nanoseconds: 200_000_000)
                shellPID = await MainActor.run { self?.pid }
                if shellPID != nil { break }
            }

            guard let shellPID else { return }

            // Step 2: Poll for a tmux client descendant of the shell.
            var sessionName: String?
            for _ in 0..<10 {  // 10 × 300ms = 3s
                try? await Task.sleep(nanoseconds: 300_000_000)
                let desc = ProcessTree.descendants(of: shellPID)
                if desc.isEmpty { continue }

                // Query tmux for all connected clients.
                let result = await Self.queryTmuxClients()
                guard let result else { continue }

                let clients = ProcessTree.parseTmuxClientList(result)
                // Find the client whose PID is a descendant of our shell.
                if let match = clients.first(where: { desc.contains($0.clientPID) }) {
                    sessionName = match.sessionName
                    break
                }
            }

            guard let sessionName else { return }
            await MainActor.run { [weak self] in
                guard let self, self.detectedTmuxSession == "tmux" else { return }
                self.detectedTmuxSession = sessionName
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
