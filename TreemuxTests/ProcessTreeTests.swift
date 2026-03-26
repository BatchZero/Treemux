//
//  ProcessTreeTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ProcessTreeTests: XCTestCase {

    // MARK: - allProcesses

    func testAllProcessesIncludesCurrentProcess() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let all = ProcessTree.allProcesses()
        XCTAssertTrue(all.contains { $0.pid == myPID },
                       "allProcesses must include the calling process")
    }

    func testAllProcessesEntriesHaveValidPIDs() {
        let all = ProcessTree.allProcesses()
        XCTAssertFalse(all.isEmpty)
        for entry in all {
            // PID 0 is the kernel idle process, so PIDs must be non-negative.
            XCTAssertGreaterThanOrEqual(entry.pid, 0, "PID must be non-negative")
        }
    }

    // MARK: - descendants

    func testDescendantsOfInitContainsCurrentProcess() {
        // PID 1 (launchd) is an ancestor of every user process.
        let desc = ProcessTree.descendants(of: 1)
        let myPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(desc.contains(myPID),
                       "descendants(of: 1) must include the test process")
    }

    func testDescendantsDoesNotIncludeRoot() {
        let desc = ProcessTree.descendants(of: 1)
        XCTAssertFalse(desc.contains(1),
                        "descendants must not include the root PID itself")
    }

    func testDescendantsOfNonexistentPIDIsEmpty() {
        // PID -999 does not exist.
        let desc = ProcessTree.descendants(of: -999)
        XCTAssertTrue(desc.isEmpty)
    }
}
