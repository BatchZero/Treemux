import XCTest
@testable import Treemux

final class ShellCommandRunnerTests: XCTestCase {

    func testRunEchoCommand() async throws {
        let result = try await ShellCommandRunner.run("/bin/echo", arguments: ["hello"])
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunFailingCommand() async throws {
        let result = try await ShellCommandRunner.run("/usr/bin/false")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testRunWithWorkingDirectory() async throws {
        let result = try await ShellCommandRunner.run("/bin/pwd", workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(result.output.contains("/tmp") || result.output.contains("/private/tmp"))
    }

    func testShellCommand() async throws {
        let result = try await ShellCommandRunner.shell("echo 'test123'")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "test123")
        XCTAssertEqual(result.exitCode, 0)
    }
}
