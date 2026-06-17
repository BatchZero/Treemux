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
}
