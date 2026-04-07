# Remote Tmux Session Restore Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable remote SSH panes to detect and restore tmux sessions on app restart, matching local pane behavior.

**Architecture:** Two-layer detection (title-change-triggered + save-time SSH probe) writes `detectedTmuxSession` on `ShellSession`. Existing snapshot/restore mechanism picks it up automatically. A one-line fix adds the missing `-t` PTY flag to the remote tmux attach SSH command.

**Tech Stack:** Swift, Foundation (Process), SSH CLI

---

### Task 1: Fix Missing `-t` Flag in Remote Tmux Attach

**Files:**
- Modify: `Treemux/Services/Terminal/SessionBackendLaunch.swift:110-132`

**Step 1: Add `-t` to SSH args in `.tmuxAttach` remote branch**

In `SessionBackendLaunch.swift`, inside the `.tmuxAttach` case, the remote branch builds SSH args but never adds `-t` for PTY allocation. Insert it right after the identity file block, before appending the destination:

```swift
// Find this block (around line 110-132):
        case .tmuxAttach(let configuration):
            // Build an ssh+tmux or local tmux attach command.
            var arguments: [String] = []
            var executablePath: String

            if configuration.isRemote, let sshTarget = configuration.sshTarget {
                executablePath = "/usr/bin/ssh"
                var sshArgs: [String] = []
                if sshTarget.port != 22 {
                    sshArgs.append(contentsOf: ["-p", String(sshTarget.port)])
                }
                if let identityFile = sshTarget.identityFile, !identityFile.isEmpty {
                    sshArgs.append(contentsOf: ["-i", identityFile])
                }
                // >>> INSERT HERE <<<
                // Force PTY allocation — tmux requires a terminal.
                sshArgs.append("-t")

                let destination: String
```

**Step 2: Build and verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/SessionBackendLaunch.swift
git commit -m "fix: add -t flag to SSH args for remote tmux attach

Without PTY allocation, tmux attach-session fails on the remote
because tmux requires a terminal. The regular SSH case already
adds -t when passing a remote command."
```

---

### Task 2: Add SSH Probe Infrastructure to ShellSession

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift`

**Step 1: Add the static SSH probe helper**

Append the following method right after the existing `queryTmuxClients()` method (after line 502, before the closing `}`):

```swift
    /// Queries a remote host for active tmux sessions via SSH.
    /// Returns the first session name, or nil if no sessions exist or SSH fails.
    nonisolated static func queryRemoteTmuxSessions(target: SSHTarget) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if target.port != 22 {
            args.append(contentsOf: ["-p", String(target.port)])
        }
        if let identityFile = target.identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-i", identityFile])
        }
        // Avoid interactive prompts and long waits.
        args.append(contentsOf: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        let destination = target.user.map { "\($0)@\(target.host)" } ?? target.host
        args.append(destination)
        args.append("tmux list-sessions -F '#{session_name}' 2>/dev/null")
        process.arguments = args

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
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else { return nil }
        // Return the first session name from the list.
        return output.components(separatedBy: "\n").first
    }
```

**Step 2: Add the instance probe method and debounce state**

Add a private property for debouncing right after the existing `private var isFocusedInWorkspace = false` (line 56):

```swift
    /// Timestamp of the last remote tmux probe, used for debouncing.
    private var lastRemoteTmuxProbeTime: Date?
```

Then add the two instance methods in the `// MARK: - Private helpers` section, after `resolveExactTmuxSession()` (after line 481):

```swift
    /// For SSH panes, probes the remote host for active tmux sessions.
    /// Sets detectedTmuxSession if a session is found.
    func probeRemoteTmuxSession() {
        guard case .ssh(let config) = backendConfiguration,
              detectedTmuxSession == nil else { return }

        let target = config.target
        Task { [weak self] in
            let sessionName = await Self.queryRemoteTmuxSessions(target: target)
            guard let sessionName else { return }
            await MainActor.run { [weak self] in
                guard let self, self.detectedTmuxSession == nil else { return }
                self.detectedTmuxSession = sessionName
            }
        }
    }

    /// Debounced version of probeRemoteTmuxSession — at most once every 5 seconds.
    private func probeRemoteTmuxIfNeeded() {
        guard case .ssh = backendConfiguration,
              detectedTmuxSession == nil else { return }

        let now = Date()
        if let last = lastRemoteTmuxProbeTime, now.timeIntervalSince(last) < 5 { return }
        lastRemoteTmuxProbeTime = now

        probeRemoteTmuxSession()
    }
```

**Step 3: Build and verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: add SSH-based remote tmux session probe infrastructure

queryRemoteTmuxSessions() SSHs into the remote host and runs
tmux list-sessions to discover active sessions. probeRemoteTmuxSession()
calls it and sets detectedTmuxSession. probeRemoteTmuxIfNeeded()
adds 5-second debouncing for use in high-frequency callbacks."
```

---

### Task 3: Wire Title-Change-Triggered Probe (Layer D)

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:111-116`

**Step 1: Add probe call to onTitleChange callback**

In `configureSurfaceCallbacks()`, add `probeRemoteTmuxIfNeeded()` after the existing `detectAITool` call:

```swift
// Current code (lines 111-116):
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
            self.detectAITool(fromTitle: title)
        }

// Replace with:
        surfaceController.onTitleChange = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.title = title
            self.detectTmux(fromTitle: title)
            self.detectAITool(fromTitle: title)
            // For SSH panes: if title-based detection didn't find tmux,
            // probe the remote host directly. Title changes after tmux
            // starts (from the inner shell's prompt) serve as the trigger.
            self.probeRemoteTmuxIfNeeded()
        }
```

**Step 2: Build and verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: trigger remote tmux probe on terminal title change

When the terminal title changes for an SSH pane and tmux has not
been detected yet, probe the remote host via SSH. This catches
tmux sessions started by the user after connecting."
```

---

### Task 4: Add Save-Time Batch Probe to WorkspaceSessionController

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift`

**Step 1: Add probeAllRemoteTmuxSessions method**

Add this method in the `// MARK: - Snapshots` section, right before `sessionSnapshots()` (before line 230):

```swift
    /// Probes all SSH panes that haven't detected a tmux session yet.
    /// Used as a safety net before saving workspace state.
    func probeAllRemoteTmuxSessions() async {
        let sshSessions = sessions.values.filter { session in
            if case .ssh = session.backendConfiguration, session.detectedTmuxSession == nil {
                return true
            }
            return false
        }
        guard !sshSessions.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for session in sshSessions {
                group.addTask {
                    guard case .ssh(let config) = await session.backendConfiguration else { return }
                    let name = await ShellSession.queryRemoteTmuxSessions(target: config.target)
                    guard let name else { return }
                    await MainActor.run {
                        if session.detectedTmuxSession == nil {
                            session.detectedTmuxSession = name
                        }
                    }
                }
            }
        }
    }
```

**Step 2: Build and verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift
git commit -m "feat: add batch remote tmux probe for save-time detection

probeAllRemoteTmuxSessions() concurrently probes all SSH panes
that haven't detected tmux yet, used as a safety net before
the final state save on app shutdown."
```

---

### Task 5: Wire Save-Time Probe into Shutdown Path

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `Treemux/App/TreemuxApp.swift`

**Step 1: Add async probe-then-save method to WorkspaceStore**

Add this method right after `saveWorkspaceState()` in `WorkspaceStore.swift` (after line 379):

```swift
    /// Probes remote SSH panes for tmux sessions, then saves workspace state.
    /// Used during shutdown to catch tmux sessions that title-based detection missed.
    func probeRemoteTmuxThenSave() async {
        // Probe all workspace controllers concurrently with a timeout.
        await withTaskGroup(of: Void.self) { group in
            for workspace in workspaces {
                // Access tabControllers via the public sessionController path
                // by probing the active controller for each workspace.
                if let ctrl = workspace.sessionController {
                    group.addTask {
                        await ctrl.probeAllRemoteTmuxSessions()
                    }
                }
            }
        }
        saveWorkspaceState()
    }
```

**Step 2: Update TreemuxApp.shutdown() to use async probe**

Replace the `shutdown()` method in `TreemuxApp.swift`:

```swift
// Current code (lines 25-28):
    /// Persists workspace state before the application terminates.
    func shutdown() {
        windowContext?.store.saveWorkspaceState()
    }

// Replace with:
    /// Persists workspace state before the application terminates.
    /// Probes remote SSH panes for tmux sessions with a 3-second timeout.
    func shutdown() {
        guard let store = windowContext?.store else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await store.probeRemoteTmuxThenSave()
            semaphore.signal()
        }
        // Wait up to 3 seconds for remote probes to complete; save anyway on timeout.
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            store.saveWorkspaceState()
        }
    }
```

**Step 3: Build and verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift Treemux/App/TreemuxApp.swift
git commit -m "feat: probe remote tmux sessions before saving on shutdown

On app termination, concurrently SSH-probe all remote panes for
tmux sessions (3s timeout), then save state. This is the safety
net for cases where title-change detection didn't fire."
```

---

### Task 6: Manual Integration Test

**Step 1: Build the app**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`

**Step 2: Launch the app**

Run: `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<ID>/Build/Products/Debug/Treemux.app`

**Step 3: Test scenario**

1. Open a remote SSH workspace
2. In the SSH pane, type `tmux new -s testremote`
3. Work briefly inside tmux
4. Quit Treemux (Cmd+Q)
5. Check `~/.treemux-debug/workspace-state.json` — verify `detectedTmuxSession: "testremote"` appears in the remote pane snapshot
6. Reopen Treemux — verify the pane automatically reattaches to the `testremote` tmux session

**Step 4: Verify local panes still work**

1. Open a local workspace
2. Type `tmux new -s testlocal`
3. Quit and reopen — should still restore correctly (regression check)
