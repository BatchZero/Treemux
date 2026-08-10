//
//  SFTPServiceTests.swift
//  TreemuxTests
//

import Citadel
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

    func testParseListingMarksSymlinkDirFromProbeSet() {
        // GNU `ls -lA --time-style=+%s` layout: perms links owner group size epoch name
        let output = """
        total 8
        lrwxrwxrwx 1 0 0 5 1700000000 dlink -> realdir
        lrwxrwxrwx 1 0 0 5 1700000000 flink -> real.txt
        """
        let entries = SFTPService.parseListing(
            output: output, parentPath: "/home/u",
            symlinkDirPaths: ["/home/u/dlink"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertTrue(byName["dlink"]!.symlinkTargetIsDirectory)
        XCTAssertFalse(byName["flink"]!.symlinkTargetIsDirectory)
    }

    func testStructuredSymlinkProbeCarriesDirectoryIdentityAndFailures() {
        let output = """
        D\t./dir link\t/srv/real dir
        F\t./file-link
        B\t./broken-link
        I\t./private-link
        U\t./unknown-link\trealpath unsupported
        """

        let resolutions = SFTPService.parseSymlinkProbe(output, parentPath: "/home/u")

        XCTAssertEqual(resolutions["/home/u/dir link"], .directory(canonicalIdentity: "/srv/real dir"))
        XCTAssertEqual(resolutions["/home/u/file-link"], .file)
        XCTAssertEqual(resolutions["/home/u/broken-link"], .broken)
        XCTAssertEqual(resolutions["/home/u/private-link"], .inaccessible)
        XCTAssertEqual(resolutions["/home/u/unknown-link"], .unresolved(reason: "realpath unsupported"))
    }

    func testHexProbeRoundTripsTabsNewlinesAndLegacyMarkerText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target directory")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let names = ["tab\tlink", "line\nlink", SFTPService.symlinkProbeMarker]
        for name in names {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path,
                withDestinationPath: target.path
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SFTPService.symlinkDirProbeFragment(maxDepth: 1)]
        process.currentDirectoryURL = root

        let result = try await SFTPService.runProcessAndCaptureOutput(process)
        XCTAssertEqual(result.exitCode, 0)
        let sections = SFTPService.splitSymlinkProbeOutput(result.output)
        XCTAssertTrue(sections.listing.isEmpty)
        let resolutions = SFTPService.parseSymlinkProbe(sections.probe, parentPath: root.path)

        for name in names {
            guard case .directory(let identity) = resolutions[root.appendingPathComponent(name).path] else {
                return XCTFail("expected directory resolution for \(name.debugDescription)")
            }
            XCTAssertTrue(identity.hasSuffix("/target directory"))
        }
    }

    func testProbeClassifiesPermissionDeniedTargetAsInaccessible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-probe-permission-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked")
        let target = locked.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("private-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SFTPService.symlinkDirProbeFragment(maxDepth: 1)]
        process.currentDirectoryURL = root

        let result = try await SFTPService.runProcessAndCaptureOutput(process)
        let sections = SFTPService.splitSymlinkProbeOutput(result.output)
        let resolutions = SFTPService.parseSymlinkProbe(sections.probe, parentPath: root.path)

        XCTAssertEqual(resolutions[link.path], .inaccessible)
    }

    func testParseListingUsesStructuredSymlinkResolution() throws {
        let output = "lrwxrwxrwx 1 0 0 5 1700000000 dlink -> realdir"
        let entries = SFTPService.parseListing(
            output: output,
            parentPath: "/home/u",
            symlinkResolutions: [
                "/home/u/dlink": .directory(canonicalIdentity: "/srv/realdir")
            ]
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.symlinkTargetResolution, .directory(canonicalIdentity: "/srv/realdir"))
    }

    func testBoundedSymlinkResolutionNeverExceedsLimit() async {
        let tracker = SymlinkConcurrencyTracker()
        let paths = (0..<12).map { "/link-\($0)" }

        let results = await SFTPService.resolveSymlinkMetadata(
            paths: paths,
            maxConcurrent: 3
        ) { path in
            await tracker.started()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.finished()
            return .directory(canonicalIdentity: "/resolved\(path)")
        }

        XCTAssertEqual(results.count, paths.count)
        let maximum = await tracker.maximum()
        XCTAssertLessThanOrEqual(maximum, 3)
    }

    func testBoundedSymlinkResolutionPreservesPerPathOutcomes() async {
        let expected: [String: SymlinkTargetResolution] = [
            "/dir": .directory(canonicalIdentity: "/canonical/dir"),
            "/file": .file,
            "/broken": .broken,
            "/private": .inaccessible,
            "/unknown": .unresolved(reason: nil),
        ]

        let results = await SFTPService.resolveSymlinkMetadata(
            paths: Array(expected.keys),
            maxConcurrent: 2
        ) { path in
            expected[path]!
        }

        XCTAssertEqual(results, expected)
    }

    func testCitadelStatusCodesMapToSymlinkResolutionFailures() {
        XCTAssertEqual(
            SFTPService.resolutionForCitadelStatusCode(.noSuchFile),
            .broken
        )
        XCTAssertEqual(
            SFTPService.resolutionForCitadelStatusCode(.permissionDenied),
            .inaccessible
        )
        XCTAssertEqual(
            SFTPService.resolutionForCitadelStatusCode(.unsupportedOperation),
            .unresolved(reason: nil)
        )
        XCTAssertEqual(
            SFTPService.resolutionForCitadelStatusCode(.failure),
            .unresolved(reason: nil)
        )
    }

    func testCitadelAttributesMapDirectoryFileAndMissingPermissions() {
        XCTAssertEqual(
            SFTPService.resolutionForCitadelAttributes(
                canonicalIdentity: "/canonical/dir", permissions: 0o040755),
            .directory(canonicalIdentity: "/canonical/dir")
        )
        XCTAssertEqual(
            SFTPService.resolutionForCitadelAttributes(
                canonicalIdentity: "/canonical/file", permissions: 0o100644),
            .file
        )
        XCTAssertEqual(
            SFTPService.resolutionForCitadelAttributes(
                canonicalIdentity: "/canonical/unknown", permissions: nil),
            .unresolved(reason: nil)
        )
    }

    func testBoundedSymlinkResolutionCancelsCooperativeRequestsPromptly() async throws {
        let task = Task {
            await SFTPService.resolveSymlinkMetadata(
                paths: (0..<20).map { "/link-\($0)" },
                maxConcurrent: 4
            ) { _ in
                do {
                    try await Task.sleep(for: .seconds(5))
                    return .file
                } catch {
                    return .unresolved(reason: nil)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        _ = await task.value

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testParseSymlinkDirProbeAbsolute() {
        let out = "/home/u/dlink\n/home/u/nested/dlink2\n"
        let set = SFTPService.parseSymlinkDirProbe(out, parentPath: nil)
        XCTAssertEqual(set, ["/home/u/dlink", "/home/u/nested/dlink2"])
    }

    func testParseSymlinkDirProbeRelativeToRoot() {
        // Bulk form: `find .` emits ./-relative paths; resolve against root.
        let out = "./dlink\n./nested/dlink2\n"
        let set = SFTPService.parseSymlinkDirProbe(out, parentPath: "/home/u")
        XCTAssertEqual(set, ["/home/u/dlink", "/home/u/nested/dlink2"])
    }

    // MARK: - exit-code preservation idiom (symlink-dir probe must never mask listing failure)

    /// Regression for the Critical bug where appending the symlink-dir probe
    /// with a bare `;` made the combined command's exit code reflect only the
    /// probe, discarding a failed listing's nonzero status. The fix captures
    /// the listing's exit code into `__tmx_rc` immediately, runs the probe
    /// best-effort, then `exit $__tmx_rc`. This drives that exact idiom
    /// through `/bin/sh -c` (no live SSH server needed) with a failing
    /// listing stub (`false`) and asserts the overall exit is still nonzero.
    func test_exitCodeIdiom_failingListing_stillYieldsNonzeroExit() async throws {
        let command = "false; __tmx_rc=$?; echo \(SFTPService.symlinkProbeMarker); true; exit $__tmx_rc"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// Same idiom, but with a succeeding listing stub (`true`) — the overall
    /// exit must be 0 so a healthy listing is never spuriously rejected.
    func test_exitCodeIdiom_succeedingListing_yieldsZeroExit() async throws {
        let command = "true; __tmx_rc=$?; echo \(SFTPService.symlinkProbeMarker); true; exit $__tmx_rc"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        XCTAssertEqual(result.exitCode, 0)
    }

    /// Contrast case locking in the regression this fix closes: the OLD
    /// `;`-without-capture form (`listing; probe`, no `__tmx_rc` capture) lets
    /// a trailing successful probe (`true`) mask a failed listing (`false`),
    /// yielding exit 0 even though the listing failed. This is exactly the
    /// bug described in the Critical review finding — a permission-denied
    /// `ls` masked by the probe's own success.
    func test_exitCodeIdiom_oldUncapturedForm_masksFailingListing() async throws {
        let command = "false; echo M; true"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        XCTAssertEqual(result.exitCode, 0, "documents the bug: old form masks a failing listing")
    }

    /// The tests above exercise the capture-and-exit idiom via hand-rolled
    /// `false`/`true` stubs, never the actual string `bulkListCommand`
    /// produces. Assert the real builder output carries the idiom too, so a
    /// future edit that accidentally drops `__tmx_rc` (or reorders it around
    /// the probe) is caught here rather than only in the stubbed tests above.
    func testBulkListCommandPreservesListingExitCode() {
        let cmd = SFTPService.bulkListCommand(maxDepth: 2)
        // The listing's exit status must be captured BEFORE the probe and re-exited
        // AFTER it, so the probe can never mask a listing/cd-root failure.
        XCTAssertTrue(cmd.contains("__tmx_rc=$?"),
                      "bulk command must capture the listing exit code before the probe")
        XCTAssertTrue(cmd.hasSuffix("exit $__tmx_rc"),
                      "bulk command must exit with the captured listing code")
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

    // MARK: - sshArgs multiplexing (P2)

    /// P2: every system-ssh invocation must carry ControlMaster options so
    /// repeated file operations reuse one authenticated connection.
    func test_sshArgs_includesConnectionMultiplexingOptions() {
        let target = SSHTarget(host: "h", port: 22, user: "u", identityFile: nil,
                               displayName: "h", remotePath: nil)
        let args = SFTPService.sshArgs(target: target, command: "echo 1")

        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains(where: { $0.hasPrefix("ControlPath=") && $0.hasSuffix("/%C") }))
        XCTAssertTrue(args.contains("ControlPersist=60s"))
        // Invocation shape unchanged: target second-to-last, command last.
        XCTAssertEqual(Array(args.suffix(2)), ["u@h", "echo 1"])
    }

    // MARK: - create directory / create file command builders

    func testMkdirCommandQuotesPath() {
        XCTAssertEqual(SFTPService.mkdirCommand(path: "/home/u/new dir"),
                       "mkdir -- '/home/u/new dir'")
    }

    func testTouchNoclobberCommandQuotesPath() {
        // noclobber (`set -C`) makes `>` fail if the file already exists.
        XCTAssertEqual(SFTPService.touchNoclobberCommand(path: "/home/u/a.txt"),
                       "set -C; : > '/home/u/a.txt'")
    }

    // MARK: - recursive name search (find)

    func testParseFindResultsTypePrefixed() {
        let out = "f /home/u/alpha.txt\nd /home/u/sub/alphadir\n\nf /home/u/beta\n"
        let entries = SFTPService.parseFindResults(out)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(byName["alpha.txt"]?.path, "/home/u/alpha.txt")
        XCTAssertTrue(byName["alphadir"]!.isDirectory)
        XCTAssertFalse(byName["alpha.txt"]!.isDirectory)
    }

    func testRecursiveSearchCommandShapes() {
        let cmd = SFTPService.recursiveSearchCommand(
            root: "/home/u", query: "log", maxDepth: 12, maxResults: 500, includeHidden: true)
        XCTAssertTrue(cmd.contains("find '/home/u' -maxdepth 12 -iname '*log*'"))
        XCTAssertTrue(cmd.contains("head -n 500"))
        XCTAssertFalse(cmd.contains("-prune"), "includeHidden: true must not prune hidden entries")
    }

    // Regression: FIX I1 (remote) — when hidden files are excluded, the
    // assembled `find` command must prune hidden directories/files so a
    // non-hidden leaf under a hidden directory (e.g. `.git/config`) can never
    // be reported. The prune must also exempt the search ROOT itself (via
    // `! -path <root>`) so a dotted root (e.g. `/home/u/.config`) is not
    // pruned before its own contents are ever visited — see
    // testRecursiveSearchCommandHiddenRootStillSearches for the empirical
    // proof of that root-exemption behavior.
    func testRecursiveSearchCommandPrunesHiddenWhenExcluded() {
        let cmdExcluded = SFTPService.recursiveSearchCommand(
            root: "/home/u", query: "log", maxDepth: 12, maxResults: 500, includeHidden: false)
        XCTAssertTrue(cmdExcluded.contains("-name '.?*' ! -path '/home/u' -prune"),
                      "includeHidden: false must prune dotted entries, exempting the root itself")

        let cmdIncluded = SFTPService.recursiveSearchCommand(
            root: "/home/u", query: "log", maxDepth: 12, maxResults: 500, includeHidden: true)
        XCTAssertFalse(cmdIncluded.contains("-prune"),
                        "includeHidden: true must not contain the prune fragment")
    }

    /// Regression for the hidden-prune fix: POSIX/BSD `find` evaluates its
    /// own starting pathname against every predicate, so `-name '.?*' -prune`
    /// alone would match a dotted search ROOT (e.g. an SSH browse root of
    /// `/home/u/.config`) and prune the entire tree before any child is ever
    /// visited — silently returning zero results even though matches exist.
    /// This drives the real generated command through `/bin/sh` against a
    /// temp directory whose root is itself dotted, asserting non-hidden
    /// matches at multiple depths ARE returned while a hidden child
    /// directory's contents are still excluded.
    func testRecursiveSearchCommandHiddenRootStillSearches() async throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmx-hidden-root-\(UUID().uuidString)")
        let dottedRoot = tmpBase.appendingPathComponent(".config")
        let subDir = dottedRoot.appendingPathComponent("sub")
        let hiddenChildDir = dottedRoot.appendingPathComponent(".hidden")

        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenChildDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        let applogPath = dottedRoot.appendingPathComponent("applog.txt")
        let deeplogPath = subDir.appendingPathComponent("deeplog.txt")
        let secretLogPath = hiddenChildDir.appendingPathComponent("secret.log")
        try "app".write(to: applogPath, atomically: true, encoding: .utf8)
        try "deep".write(to: deeplogPath, atomically: true, encoding: .utf8)
        try "secret".write(to: secretLogPath, atomically: true, encoding: .utf8)

        let cmd = SFTPService.recursiveSearchCommand(
            root: dottedRoot.path, query: "log", maxDepth: 12, maxResults: 500, includeHidden: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]

        let result = try await withTimeout(seconds: 5) {
            try await SFTPService.runProcessAndCaptureOutput(process)
        }

        let entries = SFTPService.parseFindResults(result.output)
        let paths = Set(entries.map { $0.path })

        XCTAssertTrue(paths.contains(applogPath.path),
                      "non-hidden match directly under the dotted root must be found")
        XCTAssertTrue(paths.contains(deeplogPath.path),
                      "non-hidden match nested under the dotted root must be found")
        XCTAssertFalse(paths.contains(secretLogPath.path),
                       "match under a hidden child directory must still be pruned")
    }
}

private actor SymlinkConcurrencyTracker {
    private var active = 0
    private var maximumActive = 0

    func started() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finished() {
        active -= 1
    }

    func maximum() -> Int { maximumActive }
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
