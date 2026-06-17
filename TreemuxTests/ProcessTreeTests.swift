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

    // MARK: - processEnvironment

    func testProcessEnvironmentReadsOwnEnvVars() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let env = ProcessTree.processEnvironment(pid: myPID)
        XCTAssertNotNil(env, "Must be able to read own process environment")
        // PATH is present in virtually every process.
        XCTAssertNotNil(env?["PATH"], "Environment must contain PATH")
    }

    func testProcessEnvironmentReturnsNilForInvalidPID() {
        let env = ProcessTree.processEnvironment(pid: -999)
        XCTAssertNil(env)
    }

    // MARK: - findDescendant

    func testFindDescendantMatchesOwnProcess() {
        // KERN_PROCARGS2 returns the environment as it was at process launch,
        // so we read an env var that was present when the test runner started.
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let env = ProcessTree.processEnvironment(pid: myPID),
              let pathValue = env["PATH"] else {
            XCTFail("Cannot read own environment; prerequisite check failed")
            return
        }

        // Search descendants of PID 1 for a process whose PATH matches ours.
        // Our own process must be among those descendants.
        let found = ProcessTree.findDescendant(
            of: 1,
            envKey: "PATH",
            envValue: pathValue
        )
        // At least one process must match (could be us or a sibling with identical PATH).
        XCTAssertNotNil(found, "findDescendant must find at least one process with matching PATH")
    }

    func testFindDescendantReturnsNilWhenNoMatch() {
        let found = ProcessTree.findDescendant(
            of: 1,
            envKey: "TREEMUX_NONEXISTENT_\(UUID().uuidString)",
            envValue: "impossible"
        )
        XCTAssertNil(found)
    }

    // MARK: - parseTmuxClientList

    func testParseTmuxClientListValid() {
        let output = """
        12345 mysession
        67890 another
        """
        let clients = ProcessTree.parseTmuxClientList(output)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].clientPID, 12345)
        XCTAssertEqual(clients[0].sessionName, "mysession")
        XCTAssertEqual(clients[1].clientPID, 67890)
        XCTAssertEqual(clients[1].sessionName, "another")
    }

    func testParseTmuxClientListEmpty() {
        XCTAssertTrue(ProcessTree.parseTmuxClientList("").isEmpty)
    }

    func testParseTmuxClientListMalformedLinesSkipped() {
        let output = """
        12345 ok
        not-a-pid bad
        99999 fine
        """
        let clients = ProcessTree.parseTmuxClientList(output)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].sessionName, "ok")
        XCTAssertEqual(clients[1].sessionName, "fine")
    }

    // MARK: - tmuxSessionForPane

    func testTmuxSessionForPaneMatchesClientByEnv() {
        let clients: [(clientPID: pid_t, sessionName: String)] = [
            (90475, "2"),
            (91092, "4")
        ]
        let env: (pid_t) -> [String: String]? = { pid in
            switch pid {
            case 90475: return ["TREEMUX_PANE_ID": "pane-A"]
            case 91092: return ["TREEMUX_PANE_ID": "pane-B"]
            default: return nil
            }
        }
        XCTAssertEqual(ProcessTree.tmuxSessionForPane(paneID: "pane-B", clients: clients, env: env), "4")
        XCTAssertEqual(ProcessTree.tmuxSessionForPane(paneID: "pane-A", clients: clients, env: env), "2")
    }

    func testTmuxSessionForPaneReturnsNilWhenNoEnvMatch() {
        let clients: [(clientPID: pid_t, sessionName: String)] = [(1, "s")]
        let env: (pid_t) -> [String: String]? = { _ in ["TREEMUX_PANE_ID": "other"] }
        XCTAssertNil(ProcessTree.tmuxSessionForPane(paneID: "mine", clients: clients, env: env))
    }

    func testTmuxSessionForPaneSkipsUnreadableEnv() {
        // Simulates a client whose environment can't be read (nil), followed by a
        // readable client that matches — mirrors the real case where some processes'
        // env is hidden from KERN_PROCARGS2.
        let clients: [(clientPID: pid_t, sessionName: String)] = [(10, "x"), (20, "y")]
        let env: (pid_t) -> [String: String]? = { pid in
            pid == 20 ? ["TREEMUX_PANE_ID": "mine"] : nil
        }
        XCTAssertEqual(ProcessTree.tmuxSessionForPane(paneID: "mine", clients: clients, env: env), "y")
    }
}
