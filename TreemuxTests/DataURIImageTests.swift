import XCTest
@testable import Treemux

final class DataURIImageTests: XCTestCase {
    // 1x1 transparent PNG, base64.
    private let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    func test_validDataURIDecodes() {
        let url = URL(string: "data:image/png;base64,\(pngBase64)")
        XCTAssertNotNil(DataURIImage.decode(url))
    }

    func test_remoteURLReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "https://evil.example.com/track.png")))
    }

    func test_fileURLReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "file:///etc/passwd")))
    }

    func test_nilReturnsNil() {
        XCTAssertNil(DataURIImage.decode(nil))
    }

    func test_malformedDataURIReturnsNil() {
        XCTAssertNil(DataURIImage.decode(URL(string: "data:image/png;base64,!!!notbase64")))
    }

    func test_nonImageDataURIReturnsNil() {
        // A valid base64 data URI but with a non-image MIME type must be rejected.
        let html = "PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==" // <script>alert(1)</script>
        XCTAssertNil(DataURIImage.decode(URL(string: "data:text/html;base64,\(html)")))
        XCTAssertNil(DataURIImage.decode(URL(string: "data:application/pdf;base64,\(html)")))
    }
}
