import SwiftUI
import MarkdownUI

/// Decodes ONLY `data:` image URIs. Returns nil for remote/file/malformed URLs —
/// this is the mandatory SSRF/tracking mitigation for untrusted markdown (spec §6).
enum DataURIImage {
    static func decode(_ url: URL?) -> NSImage? {
        guard let url, url.scheme == "data" else { return nil }
        let raw = url.absoluteString
        // Reject non-image data URIs (e.g., data:application/pdf, data:text/html).
        guard raw.lowercased().hasPrefix("data:image/") else { return nil }
        guard let commaIndex = raw.firstIndex(of: ","),
              raw[..<commaIndex].contains(";base64") else { return nil }
        let base64 = String(raw[raw.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}

/// MarkdownUI image provider that renders only `data:` images and blocks everything else.
/// No network request is ever made — non-data URLs return EmptyView immediately.
struct DataURIImageProvider: ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let image = DataURIImage.decode(url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Remote/file/unknown image: render nothing (no network request is ever made).
            EmptyView()
        }
    }
}
