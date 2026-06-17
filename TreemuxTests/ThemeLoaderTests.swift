//
//  ThemeLoaderTests.swift
//  TreemuxTests
//

import XCTest
import Yams
@testable import Treemux

final class ThemeLoaderTests: XCTestCase {

    func testYamsDependencyIsLinked() throws {
        struct Probe: Decodable { let a: Int }
        let decoded = try YAMLDecoder().decode(Probe.self, from: "a: 7\n")
        XCTAssertEqual(decoded.a, 7)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("themeloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, named name: String, to dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func minimalThemeYAML(id: String, name: String) -> String {
        """
        id: \(id)
        name: \(name)
        appearance: dark
        ui:
          accent: "#418ADE"
          accentOnDark: "#2997FF"
          onAccent: "#FFFFFF"
          window: "#0F1114"
          sidebar: "#0F1114"
          pane: "#111317"
          paneHeader: "#151820"
          tabBar: "#0F1114"
          statusBar: "#0F1114"
          selection: "#1A2A42"
          hairline: "#FFFFFF1A"
          textPrimary: "#F0F0F2"
          textSecondary: "#C5C8C6"
          textMuted: "#7A7A7A"
          success: "#B5BD68"
          warning: "#F0C674"
          danger: "#CC6666"
        terminal:
          foreground: "#C5C8C6"
          background: "#111317"
          cursor: "#C5C8C6"
          selection: "#373B41"
          ansi: ["#1D1F21","#CC6666","#B5BD68","#F0C674","#81A2BE","#B294BB","#8ABEB7","#C5C8C6","#969896","#CC6666","#B5BD68","#F0C674","#81A2BE","#B294BB","#8ABEB7","#FFFFFF"]
        """
    }

    func testLoadsValidThemesSortedByName() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "b-theme", name: "Bravo"), named: "b.yaml", to: dir)
        try write(minimalThemeYAML(id: "a-theme", name: "Alpha"), named: "a.yml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.map(\.name), ["Alpha", "Bravo"])
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testInvalidYAMLIsCollectedAsError() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "ok", name: "OK"), named: "ok.yaml", to: dir)
        try write("id: broken\nthis is: : not valid", named: "broken.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.map(\.id), ["ok"])
        XCTAssertEqual(result.errors.map(\.fileName), ["broken.yaml"])
    }

    func testWrongAnsiCountIsCollectedAsError() throws {
        let dir = try makeTempDir()
        let bad = minimalThemeYAML(id: "bad", name: "Bad")
            .replacingOccurrences(of: ",\"#FFFFFF\"]", with: "]")  // 15 entries
        try write(bad, named: "bad.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].message.contains("ansi"))
    }

    func testDuplicateIDKeepsFirstAndReportsError() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "dup", name: "AAA First"), named: "a-first.yaml", to: dir)
        try write(minimalThemeYAML(id: "dup", name: "ZZZ Second"), named: "z-second.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes[0].id, "dup")
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].message.contains("duplicate"))
    }

    func testMissingDirectoryReturnsEmpty() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }
}
