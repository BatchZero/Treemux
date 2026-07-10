//
//  SSHMultiplexingTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHMultiplexingTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-mux-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makeTarget(identity: String? = nil, user: String? = "alice") -> SSHTarget {
        SSHTarget(host: "example.com", port: 2222, user: user,
                  identityFile: identity, displayName: "example", remotePath: "/srv/repo")
    }

    // MARK: - controlOptions

    func test_controlOptions_createsSocketDirectoryWithOwnerOnlyPerms() throws {
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        let dir = SSHMultiplexing.controlDirectoryURL(stateDirectory: tmp)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms, 0o700)

        XCTAssertEqual(opts, [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(dir.path)/%C",
            "-o", "ControlPersist=60s"
        ])
    }

    func test_controlOptions_secondCallWithExistingDirectoryStillReturnsOptions() {
        _ = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(opts.count, 6)
    }

    func test_controlOptions_returnsEmptyWhenDirectoryCannotBeCreated() throws {
        // A regular FILE at the state-directory path makes createDirectory throw.
        try Data().write(to: tmp)
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(opts, [])
    }

    /// Arg-building must be read-only after the first successful ensure for a
    /// state directory: a per-call mkdir raced with tests/users deleting the
    /// state directory (FileManager.removeItem vs createDirectory yields
    /// NSCocoaError 513), so after the first call the options are served from
    /// cache and the directory is NOT recreated.
    func test_controlOptions_doesNotRecreateDirectoryAfterFirstCall() throws {
        _ = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        let dir = SSHMultiplexing.controlDirectoryURL(stateDirectory: tmp)
        try FileManager.default.removeItem(at: tmp)

        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)

        XCTAssertEqual(opts.count, 6, "options still served from the ensure cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "arg building must not write to the filesystem after the first ensure")
    }

    /// A failed ensure must NOT be cached: once the obstruction is removed,
    /// the next call retries and succeeds.
    func test_controlOptions_retriesAfterFailedEnsure() throws {
        // A regular FILE at the state-directory path makes createDirectory throw.
        try Data().write(to: tmp)
        let failedOpts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(failedOpts, [])

        try FileManager.default.removeItem(at: tmp)

        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(opts.count, 6, "failed ensure must not be cached; a later call retries")
    }

    // MARK: - sshArguments

    func test_sshArguments_endsWithTargetAndCommand_andCarriesBaseOptions() throws {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(), command: "echo hi", stateDirectory: tmp)

        XCTAssertEqual(Array(args.suffix(2)), ["alice@example.com", "echo hi"])
        // Base options preserved verbatim from the pre-P2 builders.
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=10"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        let pIdx = try XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertEqual(args[pIdx + 1], "2222")
        // Multiplexing options present.
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ControlPersist=60s"))
    }

    func test_sshArguments_expandsTildeInIdentityFile() throws {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(identity: "~/.ssh/id_test"), command: "true", stateDirectory: tmp)
        let iIdx = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertFalse(args[iIdx + 1].hasPrefix("~"))
        XCTAssertTrue(args[iIdx + 1].hasSuffix("/.ssh/id_test"))
    }

    func test_sshArguments_defaultsUserToCurrentUser() {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(user: nil), command: "true", stateDirectory: tmp)
        XCTAssertEqual(args.suffix(2).first, "\(NSUserName())@example.com")
    }

    func test_sshArguments_omitsMuxOptionsWhenControlDirUnavailable() throws {
        try Data().write(to: tmp)
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(), command: "true", stateDirectory: tmp)
        XCTAssertFalse(args.contains("ControlMaster=auto"))
        XCTAssertEqual(Array(args.suffix(2)), ["alice@example.com", "true"])
    }
}
