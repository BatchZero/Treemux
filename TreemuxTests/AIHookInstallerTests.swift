import XCTest
@testable import Treemux

@MainActor
final class AIHookInstallerTests: XCTestCase {

    func testRegistryStartsEmpty() {
        // Providers are registered in T11/T12/T13. This test guards against the
        // registry initializer doing something unexpected before then.
        let providers = AIHookProviderRegistry.providers()
        XCTAssertEqual(providers.count, 0)
    }

    func testHookTargetIDForLocal() {
        XCTAssertEqual(HookTarget.local.id, "local")
    }

    func testHookTargetIDForRemote() {
        let target = SSHTarget(
            host: "deploy.example.com",
            port: 22,
            user: nil,
            identityFile: nil,
            displayName: "deploy.example.com",
            remotePath: "/srv/app"
        )
        XCTAssertEqual(HookTarget.remote(target).id, "remote:deploy.example.com")
    }

    func testInMemoryFileSystemRoundTrip() async throws {
        let fs = InMemoryHookFileSystem()
        let exists0 = try await fs.exists("~/.foo")
        XCTAssertFalse(exists0)
        try await fs.writeText("~/.foo", "hello")
        let exists1 = try await fs.exists("~/.foo")
        XCTAssertTrue(exists1)
        let read1 = try await fs.readText("~/.foo")
        XCTAssertEqual(read1, "hello")
        try await fs.removeFile("~/.foo")
        let exists2 = try await fs.exists("~/.foo")
        XCTAssertFalse(exists2)
    }

    func testInMemoryFileSystemExecutableTracking() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.script.sh", "echo hi")
        let pre = try await fs.isExecutable("~/.script.sh")
        XCTAssertFalse(pre)
        try await fs.makeExecutable("~/.script.sh")
        let post = try await fs.isExecutable("~/.script.sh")
        XCTAssertTrue(post)
    }
}
