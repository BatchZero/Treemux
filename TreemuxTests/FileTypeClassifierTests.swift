//
//  FileTypeClassifierTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileTypeClassifierTests: XCTestCase {
    func testTextByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("README.md"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.swift"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("data.json"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.txt"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.YML"), .text)
    }

    func testImageByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.png"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.JPG"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("anim.gif"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("photo.heic"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("vector.svg"), .image)
    }

    func testQuickLookByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.pdf"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("clip.mp4"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("song.mp3"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.docx"), .quickLook)
    }

    func testUnknownByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.exe"), .binary)
        XCTAssertEqual(FileTypeClassifier.classifyByName("noext"), .unknown)
    }

    func testTextSniffOnUtf8Bytes() {
        let utf8 = "Hello 你好\nworld".data(using: .utf8)!
        XCTAssertEqual(FileTypeClassifier.classifyByContent(utf8), .text)
    }

    func testBinarySniffOnNullBytes() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .binary)
    }
}
