//
//  SFTPServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SFTPServiceTests: XCTestCase {
    func test_isConnected_initiallyFalse() async {
        let s = SFTPService()
        let connected = await s.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: - parseListing: GNU `ls -lA --time-style=+%s`

    /// Linux GNU `ls -lA --time-style=+%s` emits exactly seven space-separated
    /// fields per file when the name has no embedded spaces:
    ///   perms  links  owner  group  size  epoch  name
    /// Regression for the empty-tree-on-remote-Linux bug: an off-by-one guard
    /// (`>= 8`) silently dropped every single-word filename.
    func test_parseListing_GNU_singleWordFilename_isParsed() {
        let output = """
        total 24
        -rw-r--r-- 1 user users 1234 1714000000 README.md
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/home/user/proj")

        XCTAssertEqual(entries.count, 1)
        let e = try! XCTUnwrap(entries.first)
        XCTAssertEqual(e.name, "README.md")
        XCTAssertEqual(e.path, "/home/user/proj/README.md")
        XCTAssertEqual(e.sizeBytes, 1234)
        XCTAssertEqual(e.kind, .file)
        XCTAssertEqual(e.modifiedAt, Date(timeIntervalSince1970: 1714000000))
    }

    func test_parseListing_GNU_mixedKinds_areParsed() {
        let output = """
        total 12
        drwxr-xr-x 2 alice alice  4096 1714000100 src
        -rw-r--r-- 1 alice alice    42 1714000200 hello.swift
        lrwxrwxrwx 1 alice alice    11 1714000300 link -> hello.swift
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/home/alice")

        XCTAssertEqual(entries.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["src"]?.kind, .directory)
        XCTAssertEqual(byName["hello.swift"]?.kind, .file)
        XCTAssertEqual(byName["link"]?.kind, .symlink(target: "hello.swift"))
    }

    func test_parseListing_GNU_filenameWithSpaces_keepsFullName() {
        let output = "-rw-r--r-- 1 u g 7 1714000000 My Notes.txt"
        let entries = SFTPService.parseListing(output: output, parentPath: "/srv")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "My Notes.txt")
        XCTAssertEqual(entries.first?.path, "/srv/My Notes.txt")
    }

    // MARK: - parseListing: BSD `ls -lAT`

    func test_parseListing_BSD_singleWordFilename_isParsed() {
        let output = "-rw-r--r--  1 user  staff  1234 Apr 30 12:34:56 2026 README.md"
        let entries = SFTPService.parseListing(output: output, parentPath: "/Users/user/proj")

        XCTAssertEqual(entries.count, 1)
        let e = try! XCTUnwrap(entries.first)
        XCTAssertEqual(e.name, "README.md")
        XCTAssertEqual(e.sizeBytes, 1234)
        XCTAssertEqual(e.kind, .file)
        XCTAssertNotNil(e.modifiedAt)
    }

    // MARK: - parseListing: edge cases

    func test_parseListing_emptyOutput_returnsEmpty() {
        XCTAssertTrue(SFTPService.parseListing(output: "", parentPath: "/").isEmpty)
    }

    func test_parseListing_skipsTotalAndDotEntries() {
        // `ls -A` already strips `.`/`..`, but parser also drops them defensively.
        let output = """
        total 0
        drwxr-xr-x 3 u g 96 1714000000 .
        drwxr-xr-x 6 u g 96 1714000000 ..
        -rw-r--r-- 1 u g 10 1714000000 keep
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/x")
        XCTAssertEqual(entries.map(\.name), ["keep"])
    }

    func test_parseListing_joinsParentPathTrailingSlash() {
        let output = "-rw-r--r-- 1 u g 1 1714000000 file"
        let withSlash = SFTPService.parseListing(output: output, parentPath: "/x/")
        let withoutSlash = SFTPService.parseListing(output: output, parentPath: "/x")
        XCTAssertEqual(withSlash.first?.path, "/x/file")
        XCTAssertEqual(withoutSlash.first?.path, "/x/file")
    }

    // MARK: - runProcessAndCaptureOutput: pipe drain regression

    /// Regression: opening a remote file ≥ ~16 KB used to hang forever because
    /// stdout was only read in the process's `terminationHandler`. The kernel
    /// pipe buffer fills, the child blocks on write, the process never
    /// terminates, and the awaiting Task is stuck. The 100 KB output here is
    /// well past the buffer cap, so a regression of the drain logic would make
    /// this test exceed its 10 s timeout instead of finishing in milliseconds.
    func test_runProcessAndCaptureOutput_largeStdout_doesNotDeadlock() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "yes | head -c 100000"]

        let result = try await withTimeout(seconds: 10) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.count, 100_000)
    }

    func test_runProcessAndCaptureOutput_smallStdout_returnsExactBytes() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["hello"]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "hello\n")
    }

    /// Stdin write also has to stay off the cooperative pool — for a payload
    /// past the pipe buffer the synchronous write would otherwise stall the
    /// awaiting Task. This pipes 100 KB through `cat` and round-trips.
    func test_runProcessAndCaptureOutput_largeStdin_isPiped() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let payload = Data(repeating: UInt8(ascii: "x"), count: 100_000)

        let result = try await withTimeout(seconds: 10) {
            try await SFTPService.runProcessAndCaptureOutput(process, stdin: payload)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.count, 100_000)
    }

    // MARK: - runProcessAndCaptureOutput: command timeout

    /// A listing command that stalls must surface a timeout error instead of
    /// hanging the file browser forever (the "remote large folder spins
    /// forever" bug). A 5 s sleep with a 0.3 s timeout must throw promptly and
    /// leave no orphaned child process behind.
    func test_runProcessAndCaptureOutput_timeout_throwsAndKillsChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5"]

        do {
            _ = try await withTimeout(seconds: 3) {
                try await SFTPService.runProcessAndCaptureOutput(process, timeout: 0.3)
            }
            XCTFail("expected a timeout error")
        } catch is TestTimeoutError {
            XCTFail("command timeout did not fire — outer harness timed out instead")
        } catch {
            // Expected: SFTPServiceError.commandTimedOut surfaced quickly.
        }
        // `terminate()` is asynchronous — SIGTERM is delivered, but the child
        // takes a moment to actually exit. Poll briefly rather than racing it.
        var stillRunning = process.isRunning
        for _ in 0..<20 where stillRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
            stillRunning = process.isRunning
        }
        XCTAssertFalse(stillRunning, "timed-out child must be terminated")
    }

    /// A fast command finishing well inside its timeout returns normally —
    /// the timeout must not corrupt the success path.
    func test_runProcessAndCaptureOutput_withTimeout_fastCommandSucceeds() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["ok"]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process, timeout: 5)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "ok\n")
    }
}

// MARK: - Test helpers

private struct TestTimeoutError: Error {}

/// Races `body` against a timeout. Without this, a regression of the pipe
/// drain logic would hang the test runner indefinitely instead of failing.
private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
