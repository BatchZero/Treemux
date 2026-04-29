//
//  SFTPServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SFTPServiceTests: XCTestCase {
    func test_isConnected_initiallyFalse() async {
        let s = SFTPService()
        let connected = await s.isConnected
        XCTAssertFalse(connected)
    }
}
