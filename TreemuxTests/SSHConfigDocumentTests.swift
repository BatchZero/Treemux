//
//  SSHConfigDocumentTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHConfigDocumentTests: XCTestCase {

    func testRoundTripPreservesUnmanagedContent() {
        let config = """
        # global
        Host *
            ForwardAgent yes

        Host server1
            HostName 1.2.3.4
            Port 2222
            # inline note
            ProxyJump bastion
        """
        let doc = SSHConfigDocument(contents: config)
        XCTAssertEqual(doc.render(), config)
    }

    func testAllEntriesClassifiesManaged() {
        let config = """
        Host *
            ForwardAgent yes
        Host server1
            HostName 1.2.3.4
            User bob
        Host alpha beta
            HostName multi
        """
        let entries = SSHConfigDocument(contents: config).allEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries[0].isEditable)        // Host *
        XCTAssertTrue(entries[1].isEditable)
        XCTAssertEqual(entries[1].draft.alias, "server1")
        XCTAssertEqual(entries[1].draft.hostName, "1.2.3.4")
        XCTAssertEqual(entries[1].draft.user, "bob")
        XCTAssertEqual(entries[1].draft.port, 22)
        XCTAssertFalse(entries[2].isEditable)        // multi-pattern
    }

    func testAddAppendsBlockWithSeparator() {
        var doc = SSHConfigDocument(contents: "Host existing\n    HostName 1.1.1.1")
        doc.add(SSHServerDraft(alias: "newsrv", hostName: "2.2.2.2", port: 2200,
                               user: "carol", identityFile: "~/.ssh/k"))
        let expected = """
        Host existing
            HostName 1.1.1.1

        Host newsrv
            HostName 2.2.2.2
            Port 2200
            User carol
            IdentityFile ~/.ssh/k
        """
        XCTAssertEqual(doc.render(), expected)
    }

    func testAddOmitsDefaultsAndUserOnEmptyFile() {
        var doc = SSHConfigDocument(contents: "")
        doc.add(SSHServerDraft(alias: "x", hostName: "h"))
        XCTAssertEqual(doc.render(), "Host x\n    HostName h")
    }
}
