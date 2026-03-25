//
//  SSHConfigParserTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHConfigParserTests: XCTestCase {

    func testParseBasicHost() {
        let config = """
        Host server1
            HostName 192.168.1.100
            User user1
            Port 22
            IdentityFile ~/.ssh/id_rsa
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].displayName, "server1")
        XCTAssertEqual(targets[0].host, "192.168.1.100")
        XCTAssertEqual(targets[0].user, "user1")
        XCTAssertEqual(targets[0].port, 22)
        XCTAssertEqual(targets[0].identityFile, "~/.ssh/id_rsa")
    }

    func testParseMultipleHosts() {
        let config = """
        Host dev
            HostName dev.example.com
            User developer
            Port 2222

        Host prod
            HostName prod.example.com
            User admin
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets[0].displayName, "dev")
        XCTAssertEqual(targets[0].host, "dev.example.com")
        XCTAssertEqual(targets[0].port, 2222)
        XCTAssertEqual(targets[1].displayName, "prod")
        XCTAssertEqual(targets[1].host, "prod.example.com")
        XCTAssertEqual(targets[1].user, "admin")
        XCTAssertEqual(targets[1].port, 22) // default
    }

    func testSkipWildcardHosts() {
        let config = """
        Host *
            ServerAliveInterval 60

        Host server1
            HostName 10.0.0.1
            User user1
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].displayName, "server1")
    }

    func testSkipComments() {
        let config = """
        # This is a comment
        Host myhost
            # Another comment
            HostName 10.0.0.2
            User myuser
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].host, "10.0.0.2")
    }

    func testHostWithoutHostname() {
        let config = """
        Host myserver
            User user1
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertEqual(targets.count, 1)
        // When HostName is not specified, host alias is used as hostname
        XCTAssertEqual(targets[0].host, "myserver")
        XCTAssertEqual(targets[0].displayName, "myserver")
    }

    func testEmptyConfig() {
        let targets = SSHConfigParser.parse(contents: "")
        XCTAssertTrue(targets.isEmpty)
    }

    func testRemotePathIsNil() {
        let config = """
        Host server1
            HostName 10.0.0.1
        """
        let targets = SSHConfigParser.parse(contents: config)
        XCTAssertNil(targets[0].remotePath)
    }
}
