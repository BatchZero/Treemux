import XCTest
@testable import Treemux

@MainActor
final class RemoteHookFileSystemTests: XCTestCase {

    /// Confirm that special characters in a path are quoted such that the
    /// remote shell receives them verbatim.
    func testShellQuoteHandlesSpaces() {
        let fs = RemoteHookFileSystemTesting.shellQuote("path with spaces")
        XCTAssertEqual(fs, "'path with spaces'")
    }

    func testShellQuoteEscapesSingleQuote() {
        let fs = RemoteHookFileSystemTesting.shellQuote("o'malley")
        XCTAssertEqual(fs, "'o'\\''malley'")
    }

    func testExpandReturnsPathUnchanged() async throws {
        let target = SSHTarget(
            host: "example.com",
            port: 22,
            user: nil,
            identityFile: nil,
            displayName: "example.com",
            remotePath: nil
        )
        let fs = RemoteHookFileSystem(target: target)
        let p = try await fs.expand("~/.treemux/hooks/notify.sh")
        XCTAssertEqual(p, "~/.treemux/hooks/notify.sh", "Remote FS should NOT expand ~/ on the client side")
    }

    func testSSHArgsIncludePort() {
        let target = SSHTarget(
            host: "example.com",
            port: 2222,
            user: "alice",
            identityFile: nil,
            displayName: "alice@example.com",
            remotePath: nil
        )
        let args = RemoteHookFileSystemTesting.sshArgs(for: "echo hi", target: target)
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
        XCTAssertTrue(args.contains("alice@example.com"))
    }

    func testSSHArgsOmitDefaultPort() {
        let target = SSHTarget(
            host: "example.com",
            port: 22,
            user: nil,
            identityFile: nil,
            displayName: "example.com",
            remotePath: nil
        )
        let args = RemoteHookFileSystemTesting.sshArgs(for: "echo hi", target: target)
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("22"))
    }

    func testSSHArgsIncludeIdentityFile() {
        let target = SSHTarget(
            host: "example.com",
            port: 22,
            user: nil,
            identityFile: "~/.ssh/key",
            displayName: "example.com",
            remotePath: nil
        )
        let args = RemoteHookFileSystemTesting.sshArgs(for: "echo hi", target: target)
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("~/.ssh/key"))
    }
}
