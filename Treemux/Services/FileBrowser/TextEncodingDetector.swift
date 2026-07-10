import Foundation

/// Detects text encoding by attempting UTF-8 → GB18030 → Latin-1 in order.
/// Pure function, safe on any thread; `loadText` runs it off the main
/// actor so multi-MB files don't stall the UI.
enum TextEncodingDetector {
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return (s, gbk) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
