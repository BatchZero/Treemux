//
//  AIToolModels.swift
//  Treemux
//

import Foundation

/// Result of detecting an AI tool running inside a terminal pane.
struct AIToolDetection: Equatable {
    let kind: AIToolKind
    let isRunning: Bool
    let processName: String

    static func == (lhs: AIToolDetection, rhs: AIToolDetection) -> Bool {
        lhs.kind == rhs.kind && lhs.isRunning == rhs.isRunning && lhs.processName == rhs.processName
    }
}

// MARK: - AIToolKind extensions for detection and display

extension AIToolKind {

    /// Display name shown in UI badges and menus.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openaiCodex: return "Codex"
        case .custom: return "AI Agent"
        }
    }

    /// SF Symbol name for the badge icon.
    var iconName: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .openaiCodex: return "wand.and.stars"
        case .custom: return "cpu"
        }
    }

    /// Detect AI tool kind from a process name.
    static func detect(processName: String) -> AIToolKind? {
        let lower = processName.lowercased()
        if lower == "claude" || lower.hasPrefix("claude-") || lower.contains("claude_code") {
            return .claudeCode
        }
        if lower == "codex" || lower.hasPrefix("codex-") {
            return .openaiCodex
        }
        return nil
    }
}
