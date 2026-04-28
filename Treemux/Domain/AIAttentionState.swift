//
//  AIAttentionState.swift
//  Treemux
//

import Foundation

/// Whether a shell session is currently asking for the user's attention because
/// an AI agent (Claude Code / Codex / opencode) finished its turn or is waiting
/// for input. Driven by OSC 777 desktop notifications emitted by treemux-managed
/// hooks (see docs/plans/2026-04-28-sidebar-ai-attention-design.md).
enum AIAttentionState: Equatable {
    case none
    case done
    case input

    /// Map an OSC 777 notification title to a state, or nil if the title is not
    /// one of treemux's known prefixes.
    static func parse(notificationTitle title: String) -> AIAttentionState? {
        switch title {
        case "treemux:done":  return .done
        case "treemux:input": return .input
        default:              return nil
        }
    }
}
