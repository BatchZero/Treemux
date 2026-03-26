# PID-Based Tmux Session Matching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the 1.5s delay + "most recent session" heuristic for bare tmux with precise PID-based process tree matching.

**Architecture:** Inject a unique `TREEMUX_PANE_ID` env var per pane, use macOS `sysctl` to walk the process tree from the app PID, find each pane's shell process by env match, then locate its tmux client descendant and cross-reference with `tmux list-clients` to get the exact session name.

**Tech Stack:** Swift, macOS Darwin sysctl API (`KERN_PROC_ALL`, `KERN_PROCARGS2`), tmux CLI

---

### Task 1: ProcessTree utility — process enumeration and tree walking

**Files:**
- Create: `Treemux/Services/Process/ProcessTree.swift`
- Create: `TreemuxTests/ProcessTreeTests.swift`

**Step 1: Write the failing tests**

In `TreemuxTests/ProcessTreeTests.swift`:

```swift
//
//  ProcessTreeTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ProcessTreeTests: XCTestCase {

    // MARK: - allProcesses

    func testAllProcessesIncludesCurrentProcess() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let all = ProcessTree.allProcesses()
        XCTAssertTrue(all.contains { $0.pid == myPID },
                       "allProcesses must include the calling process")
    }

    func testAllProcessesEntriesHaveValidPIDs() {
        let all = ProcessTree.allProcesses()
        XCTAssertFalse(all.isEmpty)
        for entry in all {
            XCTAssertGreaterThan(entry.pid, 0, "PID must be positive")
        }
    }

    // MARK: - descendants

    func testDescendantsOfInitContainsCurrentProcess() {
        // PID 1 (launchd) is an ancestor of every user process.
        let desc = ProcessTree.descendants(of: 1)
        let myPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(desc.contains(myPID),
                       "descendants(of: 1) must include the test process")
    }

    func testDescendantsDoesNotIncludeRoot() {
        let desc = ProcessTree.descendants(of: 1)
        XCTAssertFalse(desc.contains(1),
                        "descendants must not include the root PID itself")
    }

    func testDescendantsOfNonexistentPIDIsEmpty() {
        // PID -999 does not exist.
        let desc = ProcessTree.descendants(of: -999)
        XCTAssertTrue(desc.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/ProcessTreeTests 2>&1 | tail -20`
Expected: Compilation error — `ProcessTree` not defined.

**Step 3: Write the implementation**

In `Treemux/Services/Process/ProcessTree.swift`:

```swift
//
//  ProcessTree.swift
//  Treemux
//

import Darwin
import Foundation

/// Walks the macOS process tree using sysctl to discover descendant processes
/// and read their environment variables.
enum ProcessTree {

    struct ProcessEntry {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
    }

    // MARK: - Process enumeration

    /// Returns all processes visible to the current user.
    static func allProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return (0..<actualCount).map { i in
            let kp = procList[i]
            let comm = withUnsafePointer(to: kp.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: kp.kp_proc.p_comm)
                ) { String(cString: $0) }
            }
            return ProcessEntry(
                pid: kp.kp_proc.p_pid,
                parentPID: kp.kp_eproc.e_ppid,
                command: comm
            )
        }
    }

    // MARK: - Tree walking

    /// Returns all descendant PIDs of `rootPID` (not including `rootPID` itself).
    static func descendants(of rootPID: pid_t) -> Set<pid_t> {
        let all = allProcesses()
        var children: [pid_t: [pid_t]] = [:]
        for entry in all {
            children[entry.parentPID, default: []].append(entry.pid)
        }

        var result = Set<pid_t>()
        var queue = children[rootPID] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard result.insert(pid).inserted else { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/ProcessTreeTests 2>&1 | tail -20`
Expected: All 5 tests PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/Process/ProcessTree.swift TreemuxTests/ProcessTreeTests.swift
git commit -m "feat: add ProcessTree utility with process enumeration and tree walking"
```

---

### Task 2: ProcessTree — environment reading and descendant lookup

**Files:**
- Modify: `Treemux/Services/Process/ProcessTree.swift`
- Modify: `TreemuxTests/ProcessTreeTests.swift`

**Step 1: Write the failing tests**

Append to `TreemuxTests/ProcessTreeTests.swift`:

```swift
    // MARK: - processEnvironment

    func testProcessEnvironmentReadsOwnEnvVars() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let env = ProcessTree.processEnvironment(pid: myPID)
        XCTAssertNotNil(env, "Must be able to read own process environment")
        // PATH is present in virtually every process.
        XCTAssertNotNil(env?["PATH"], "Environment must contain PATH")
    }

    func testProcessEnvironmentReturnsNilForInvalidPID() {
        let env = ProcessTree.processEnvironment(pid: -999)
        XCTAssertNil(env)
    }

    // MARK: - findDescendant

    func testFindDescendantMatchesOwnProcess() {
        // Set a unique env var in *this* process, then search from PID 1.
        let marker = "TREEMUX_TEST_\(UUID().uuidString)"
        setenv(marker, "1", 1)
        defer { unsetenv(marker) }

        let found = ProcessTree.findDescendant(
            of: 1,
            envKey: marker,
            envValue: "1"
        )
        XCTAssertEqual(found, ProcessInfo.processInfo.processIdentifier)
    }

    func testFindDescendantReturnsNilWhenNoMatch() {
        let found = ProcessTree.findDescendant(
            of: 1,
            envKey: "TREEMUX_NONEXISTENT_\(UUID().uuidString)",
            envValue: "impossible"
        )
        XCTAssertNil(found)
    }

    // MARK: - parseTmuxClientList

    func testParseTmuxClientListValid() {
        let output = """
        12345 mysession
        67890 another
        """
        let clients = ProcessTree.parseTmuxClientList(output)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].clientPID, 12345)
        XCTAssertEqual(clients[0].sessionName, "mysession")
        XCTAssertEqual(clients[1].clientPID, 67890)
        XCTAssertEqual(clients[1].sessionName, "another")
    }

    func testParseTmuxClientListEmpty() {
        XCTAssertTrue(ProcessTree.parseTmuxClientList("").isEmpty)
    }

    func testParseTmuxClientListMalformedLinesSkipped() {
        let output = """
        12345 ok
        not-a-pid bad
        99999 fine
        """
        let clients = ProcessTree.parseTmuxClientList(output)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].sessionName, "ok")
        XCTAssertEqual(clients[1].sessionName, "fine")
    }
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/ProcessTreeTests 2>&1 | tail -20`
Expected: Compilation error — `processEnvironment`, `findDescendant`, `parseTmuxClientList` not defined.

**Step 3: Write the implementation**

Append to `Treemux/Services/Process/ProcessTree.swift`, inside the `ProcessTree` enum:

```swift
    // MARK: - Environment reading

    /// Reads the environment variables of a process using KERN_PROCARGS2.
    /// Returns nil if the process cannot be read (wrong user, zombie, invalid PID).
    static func processEnvironment(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32) | exec_path\0 | padding NULLs | argv[0]\0 ... argv[argc-1]\0 | env[0]\0 ...
        let argc = buffer.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }

        var offset = MemoryLayout<Int32>.size

        // Skip exec_path
        while offset < size, buffer[offset] != 0 { offset += 1 }
        // Skip trailing NULLs after exec_path
        while offset < size, buffer[offset] == 0 { offset += 1 }

        // Skip argv[0..argc-1]
        var argsSeen: Int32 = 0
        while offset < size, argsSeen < argc {
            while offset < size, buffer[offset] != 0 { offset += 1 }
            offset += 1
            argsSeen += 1
        }

        // Parse environment variables
        var env: [String: String] = [:]
        while offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            if offset > start,
               let entry = String(bytes: buffer[start..<offset], encoding: .utf8),
               let eqIdx = entry.firstIndex(of: "=") {
                env[String(entry[..<eqIdx])] = String(entry[entry.index(after: eqIdx)...])
            }
            offset += 1
        }

        return env.isEmpty ? nil : env
    }

    // MARK: - Descendant lookup

    /// Finds the first descendant of `rootPID` whose environment contains `envKey=envValue`.
    static func findDescendant(
        of rootPID: pid_t,
        envKey: String,
        envValue: String
    ) -> pid_t? {
        for pid in descendants(of: rootPID) {
            if let env = processEnvironment(pid: pid),
               env[envKey] == envValue {
                return pid
            }
        }
        return nil
    }

    // MARK: - Tmux client list parsing

    /// Parses the output of `tmux list-clients -F '#{client_pid} #{session_name}'`.
    static func parseTmuxClientList(
        _ output: String
    ) -> [(clientPID: pid_t, sessionName: String)] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return (clientPID: pid, sessionName: String(parts[1]))
        }
    }
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/ProcessTreeTests 2>&1 | tail -20`
Expected: All 10 tests PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/Process/ProcessTree.swift TreemuxTests/ProcessTreeTests.swift
git commit -m "feat: add ProcessTree environment reading, descendant lookup, and tmux client parsing"
```

---

### Task 3: Inject TREEMUX_PANE_ID into ShellSession environment

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:60-99` (both init methods)

**Step 1: Write the failing test**

Append to `TreemuxTests/ProcessTreeTests.swift` (or a new file if preferred — but this is quick enough to keep together):

We can't easily test ShellSession init in unit tests (it creates Ghostty surfaces). Instead, test the environment helper directly. Add a static helper method to ShellSession that we can test.

Actually, the simpler approach: verify the env var appears in `launchConfiguration.environment` after init. But ShellSession's `launchConfiguration` is private. The most pragmatic test is to verify the injected env var propagates via a focused ProcessTree test after the integration is wired. Since Task 2 already proved `findDescendant` works with env vars, and the injection is a 2-line change, we proceed with implementation and verify via the existing test coverage.

**Step 2: Implement the change**

In `Treemux/Services/Terminal/ShellSession.swift`, modify the first `init` (line 60-81):

Replace lines 65-68:
```swift
        let launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: ShellSession.defaultEnvironment()
        )
```
With:
```swift
        var baseEnv = ShellSession.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        let launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
```

Modify the second `init` (line 83-99):

Replace lines 92-95:
```swift
        self.launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: ShellSession.defaultEnvironment()
        )
```
With:
```swift
        var baseEnv = ShellSession.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        self.launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
```

Modify `start()` (line 175-188):

Replace lines 176-178:
```swift
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: Self.defaultEnvironment()
        )
```
With:
```swift
        var baseEnv = Self.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
```

Modify `restart(in:)` (line 190-206):

Replace lines 196-198:
```swift
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: Self.defaultEnvironment()
        )
```
With:
```swift
        var baseEnv = Self.defaultEnvironment()
        baseEnv["TREEMUX_PANE_ID"] = id.uuidString
        launchConfiguration = backendConfiguration.makeLaunchConfiguration(
            preferredWorkingDirectory: preferredWorkingDirectory,
            baseEnvironment: baseEnv
        )
```

**Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Run full test suite**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All existing tests still pass.

**Step 5: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: inject TREEMUX_PANE_ID environment variable per pane"
```

---

### Task 4: Replace syncManagedProcessStateAfterLaunch with resolveShellPID

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:313-316` (replace `syncManagedProcessStateAfterLaunch`)

**Step 1: Write the implementation**

In `ShellSession.swift`, replace `syncManagedProcessStateAfterLaunch()` (lines 313-316):

```swift
    private func syncManagedProcessStateAfterLaunch() {
        pid = surfaceController.managedPID
        lifecycle = (surfaceController.isManagedSessionRunning || pid != nil) ? .running : .starting
    }
```

With:

```swift
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
```

**Step 2: Build and run tests**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass.

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: resolve shell PID via process tree instead of Ghostty managedPID"
```

---

### Task 5: Replace resolveRecentTmuxSession with resolveExactTmuxSession

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift:342-436`

**Step 1: Write the implementation**

In `ShellSession.swift`, in `detectTmux(fromTitle:)` (line 369), replace the call:

```swift
            resolveRecentTmuxSession()
```

With:

```swift
            resolveExactTmuxSession()
```

Then replace `resolveRecentTmuxSession()` and `findMostRecentTmuxSession()` (lines 399-436) with:

```swift
    /// When bare `tmux` is detected, resolve the exact session by finding the tmux
    /// client process that is a descendant of this pane's shell in the process tree.
    private func resolveExactTmuxSession() {
        let paneID = id.uuidString
        let appPID = ProcessInfo.processInfo.processIdentifier
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
```

**Step 2: Build and run tests**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass.

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/ShellSession.swift
git commit -m "feat: replace tmux session heuristic with exact PID-based matching"
```

---

### Task 6: Manual verification

**Step 1: Build the app**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`

**Step 2: Launch and test scenarios**

1. **Single bare tmux**: Open a pane, type `tmux`. Verify `detectedTmuxSession` resolves to the actual session name (e.g., `"0"`), not the placeholder `"tmux"`.

2. **Two bare tmux simultaneously**: Open two panes, type `tmux` in both quickly. Verify each pane detects a different session name.

3. **Named tmux**: Type `tmux new -s hello`. Verify `detectedTmuxSession = "hello"` (this path is unchanged, should still work).

4. **Save/restore**: With a tmux session running, close and reopen the workspace. Verify the session reattaches correctly.

**Step 3: Final commit (if any adjustments needed)**

```bash
git add -A
git commit -m "fix: adjustments from manual verification"
```
