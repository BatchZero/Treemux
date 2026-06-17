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

    func test_roundTripWithViewMode() throws {
        let r = FileSubTabRecord(id: UUID(), path: "/a/b.md", isPinned: true, viewMode: .render)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: data)
        XCTAssertEqual(decoded.viewMode, .render)
    }

    func test_decodesLegacyRecordWithoutViewMode() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","path":"/a/b.md","isPinned":true}"#
        let decoded = try JSONDecoder().decode(FileSubTabRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.viewMode)
    }
}
