//
//  PerfSignpost.swift
//  Treemux

import OSLog

/// os_signpost wrappers used by the perf baseline (docs/perf/baseline.md).
/// Intervals/events are recorded under subsystem "com.batchzero.treemux",
/// category "perf" — filter with Instruments or `log stream`.
enum PerfSignpost {
    static let signposter = OSSignposter(subsystem: "com.batchzero.treemux", category: "perf")

    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
