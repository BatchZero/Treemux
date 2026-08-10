import XCTest
@testable import Treemux

final class FileNodeSymlinkTests: XCTestCase {
    private func node(_ kind: FileNode.Kind, targetDir: Bool = false) -> FileNode {
        FileNode(id: "/p", name: "p", path: "/p", kind: kind,
                 sizeBytes: nil, modifiedAt: nil, symlinkTargetIsDirectory: targetDir)
    }

    func testRealDirectoryIsExpandable() {
        XCTAssertTrue(node(.directory).isExpandableDirectory)
    }

    func testFileIsNotExpandable() {
        XCTAssertFalse(node(.file).isExpandableDirectory)
    }

    func testSymlinkToDirectoryIsExpandable() {
        XCTAssertTrue(node(.symlink(target: "/t"), targetDir: true).isExpandableDirectory)
    }

    func testResolvedDirectoryCarriesCanonicalIdentity() {
        let node = FileNode(
            id: "/root/link", name: "link", path: "/root/link",
            kind: .symlink(target: "../target"), sizeBytes: nil, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/target")
        )

        XCTAssertEqual(
            node.symlinkTargetResolution,
            .directory(canonicalIdentity: "/target")
        )
        XCTAssertEqual(node.canonicalDirectoryIdentity, "/target")
        XCTAssertTrue(node.isExpandableDirectory)
    }

    func testNonDirectorySymlinkOutcomesAreNotExpandable() {
        let outcomes: [SymlinkTargetResolution] = [
            .file,
            .broken,
            .inaccessible,
            .unresolved(reason: "server does not support realpath")
        ]

        for outcome in outcomes {
            let node = FileNode(
                id: "/root/link", name: "link", path: "/root/link",
                kind: .symlink(target: "target"), sizeBytes: nil, modifiedAt: nil,
                symlinkTargetResolution: outcome
            )
            XCTAssertFalse(node.isExpandableDirectory, "Unexpected expandable outcome: \(outcome)")
            XCTAssertNil(node.canonicalDirectoryIdentity)
        }
    }

    func testRichResolutionRoundTripsThroughSnapshotEncoding() throws {
        let original = FileNode(
            id: "/root/link", name: "link", path: "/root/link",
            kind: .symlink(target: "target"), sizeBytes: 12, modifiedAt: nil,
            symlinkTargetResolution: .directory(canonicalIdentity: "/srv/target")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileNode.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testSymlinkToFileIsNotExpandable() {
        XCTAssertFalse(node(.symlink(target: "/t"), targetDir: false).isExpandableDirectory)
    }

    func testDefaultFlagIsFalse() {
        let n = FileNode(id: "/p", name: "p", path: "/p", kind: .symlink(target: "/t"),
                         sizeBytes: nil, modifiedAt: nil)
        XCTAssertFalse(n.symlinkTargetIsDirectory)
    }

    func testDecodesLegacyJSONWithoutFlag() throws {
        // A snapshot encoded before the flag existed must still decode.
        let legacy = #"{"id":"/p","name":"p","path":"/p","kind":{"symlink":{"target":"/t"}},"sizeBytes":null,"modifiedAt":null}"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(FileNode.self, from: data)
        XCTAssertFalse(decoded.symlinkTargetIsDirectory)
        XCTAssertEqual(decoded.symlinkTargetResolution, .unresolved(reason: nil))
    }

    func testLegacyDirectoryFlagDoesNotInventCanonicalIdentity() throws {
        let legacy = #"{"id":"/p","name":"p","path":"/p","kind":{"symlink":{"target":"/t"}},"sizeBytes":null,"modifiedAt":null,"symlinkTargetIsDirectory":true}"#

        let decoded = try JSONDecoder().decode(FileNode.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.symlinkTargetResolution, .unresolved(reason: nil))
        XCTAssertFalse(decoded.isExpandableDirectory)
        XCTAssertNil(decoded.canonicalDirectoryIdentity)
    }
}
