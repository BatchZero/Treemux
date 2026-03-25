//
//  AIToolServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class AIToolServiceTests: XCTestCase {

    func testDetectClaudeCode() {
        XCTAssertEqual(AIToolKind.detect(processName: "claude"), .claudeCode)
        XCTAssertEqual(AIToolKind.detect(processName: "claude-code"), .claudeCode)
        XCTAssertEqual(AIToolKind.detect(processName: "Claude"), .claudeCode)
    }

    func testDetectCodex() {
        XCTAssertEqual(AIToolKind.detect(processName: "codex"), .openaiCodex)
        XCTAssertEqual(AIToolKind.detect(processName: "codex-cli"), .openaiCodex)
    }

    func testDetectUnknown() {
        XCTAssertNil(AIToolKind.detect(processName: "vim"))
        XCTAssertNil(AIToolKind.detect(processName: "zsh"))
        XCTAssertNil(AIToolKind.detect(processName: "node"))
    }

    func testAIToolKindDisplayName() {
        XCTAssertEqual(AIToolKind.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AIToolKind.openaiCodex.displayName, "Codex")
        XCTAssertEqual(AIToolKind.custom.displayName, "AI Agent")
    }

    func testAIToolKindIconName() {
        XCTAssertFalse(AIToolKind.claudeCode.iconName.isEmpty)
        XCTAssertFalse(AIToolKind.openaiCodex.iconName.isEmpty)
        XCTAssertFalse(AIToolKind.custom.iconName.isEmpty)
    }

    @MainActor
    func testServiceDetect() {
        let service = AIToolService()
        let detection = service.detect(processName: "claude")
        XCTAssertNotNil(detection)
        XCTAssertEqual(detection?.kind, .claudeCode)
        XCTAssertTrue(detection?.isRunning ?? false)
    }

    @MainActor
    func testServiceBuiltInPresets() {
        let service = AIToolService()
        XCTAssertGreaterThanOrEqual(service.presets.count, 2)
        XCTAssertTrue(service.presets.contains(where: { $0.toolKind == .claudeCode }))
        XCTAssertTrue(service.presets.contains(where: { $0.toolKind == .openaiCodex }))
    }

    func testAgentSessionConfigCodable() throws {
        let config = AgentSessionConfig(
            name: "Test Agent",
            launchCommand: "/usr/bin/test",
            arguments: ["--flag"],
            environment: ["KEY": "VALUE"],
            toolKind: .custom
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentSessionConfig.self, from: data)
        XCTAssertEqual(decoded.name, "Test Agent")
        XCTAssertEqual(decoded.toolKind, .custom)
    }
}
