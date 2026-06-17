//
//  BuiltInThemesTests.swift
//  TreemuxTests
//

import XCTest
import Yams
@testable import Treemux

final class BuiltInThemesTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBuiltInYAMLParsesAndValidates() throws {
        for yaml in [BuiltInThemes.darkYAML, BuiltInThemes.lightYAML] {
            let theme = try Yams.YAMLDecoder().decode(Theme.self, from: yaml)
            XCTAssertNoThrow(try theme.validate())
        }
    }

    func testEnsureInstalledWritesBothThenLoaderFindsThem() throws {
        let dir = try makeTempDir()
        try BuiltInThemes.ensureInstalled(in: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(Set(result.themes.map(\.id)), Set(["treemux-dark", "treemux-light"]))
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testEnsureInstalledDoesNotOverwriteExisting() throws {
        let dir = try makeTempDir()
        let darkFile = dir.appendingPathComponent("treemux-dark.yaml")
        try "id: treemux-dark\n# user edited".write(to: darkFile, atomically: true, encoding: .utf8)
        try BuiltInThemes.ensureInstalled(in: dir)
        let contents = try String(contentsOf: darkFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("user edited"))
    }

    func testRestoreOverwrites() throws {
        let dir = try makeTempDir()
        let darkFile = dir.appendingPathComponent("treemux-dark.yaml")
        try "garbage".write(to: darkFile, atomically: true, encoding: .utf8)
        try BuiltInThemes.restore(in: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.contains(where: { $0.id == "treemux-dark" }))
    }

    func testFallbackDarkParses() {
        XCTAssertEqual(BuiltInThemes.fallbackDark().id, "treemux-dark")
    }
}
