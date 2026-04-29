//
//  FileSubTabRecordCodingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileSubTabRecordCodingTests: XCTestCase {
    func test_roundTrip() throws {
        let r = FileSubTabRecord(id: UUID(), path: "/a/b.swift", isPinned: true)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: data)
        XCTAssertEqual(decoded, r)
    }
}
