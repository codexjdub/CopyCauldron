import Foundation
import AppKit

/// What kind of content a text clipboard item is, so the row icon can adapt.
enum TextKind: Equatable {
    case plain
    case url
    case email
    case json
    case phone
    case hexColor(NSColor)
    case ipAddress
    case uuid
    case gitSHA
    case timestamp
    case base64
    case currency
    case hashtag
    case mention

    // Detectors are expensive to instantiate (`NSDataDetector` does linguistic
    // tagging setup under the hood). Hoist them to `static let` so they're
    // built once per process, not once per `detect` call.
    private static let linkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let phoneDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )
    private static let iso8601Formatter = ISO8601DateFormatter()

    static func detect(in text: String) -> TextKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        // Order matters: most specific patterns first.

        if let color = NSColor(hexString: trimmed) { return .hexColor(color) }
        if isUUID(trimmed)        { return .uuid }
        if isGitSHA(trimmed)      { return .gitSHA }
        if isIPAddress(trimmed)   { return .ipAddress }
        if isTimestamp(trimmed)   { return .timestamp }

        // URL / email — entire trimmed string must be a single link.
        let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
        if let detector = linkDetector,
           let match = detector.firstMatch(in: trimmed, options: [], range: nsRange),
           match.range == nsRange,
           let url = match.url {
            return url.scheme?.lowercased() == "mailto" ? .email : .url
        }

        if isCurrency(trimmed)    { return .currency }
        if isHashtag(trimmed)     { return .hashtag }
        if isMention(trimmed)     { return .mention }

        // Phone — only when the full trimmed string is a phone number.
        if let detector = phoneDetector,
           let match = detector.firstMatch(in: trimmed, options: [], range: nsRange),
           match.range == nsRange {
            return .phone
        }

        // JSON — must be an object or array, not a bare primitive.
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           obj is [String: Any] || obj is [Any] {
            return .json
        }

        // Base64 — last (lowest confidence). Only flag long, decodable strings.
        if isBase64(trimmed) { return .base64 }

        return .plain
    }

    // MARK: – Helpers

    private static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Exactly 40 hex chars — a full Git commit SHA. (Short SHAs overlap too
    /// much with random hex to be reliable.)
    private static func isGitSHA(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    private static func isIPAddress(_ s: String) -> Bool {
        // IPv4
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ part in
            guard !part.isEmpty, part.count <= 3,
                  let n = Int(part), n >= 0, n <= 255 else { return false }
            return true
        }) { return true }

        // IPv6 (basic — must contain :, only hex/colons, 3..8 groups)
        if s.contains(":"),
           s.range(of: #"^[0-9a-fA-F:]+$"#, options: .regularExpression) != nil {
            let groups = s.split(separator: ":", omittingEmptySubsequences: true)
            if (3...8).contains(groups.count),
               groups.allSatisfy({ $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }) {
                return true
            }
        }
        return false
    }

    private static func isTimestamp(_ s: String) -> Bool {
        // Unix epoch — 10 digits (seconds) or 13 digits (milliseconds), in a
        // sensible range (years ~2001–2286).
        if s.allSatisfy(\.isNumber), let n = Double(s) {
            if s.count == 10, n > 1_000_000_000, n < 10_000_000_000 { return true }
            if s.count == 13, n > 1_000_000_000_000, n < 10_000_000_000_000 { return true }
        }
        // ISO 8601 — anything `iso8601Formatter` can parse.
        if iso8601Formatter.date(from: s) != nil { return true }
        return false
    }

    private static func isCurrency(_ s: String) -> Bool {
        // Leading currency symbol: $12, €10.50, £5.99, ¥1000, ₹500, ₩1000
        let pattern = #"^[$€£¥₹₩]\s?\d{1,3}(?:[,]?\d{3})*(?:[.,]\d{1,2})?$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isHashtag(_ s: String) -> Bool {
        guard s.hasPrefix("#"), s.count > 1 else { return false }
        return s.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isMention(_ s: String) -> Bool {
        guard s.hasPrefix("@"), s.count > 1 else { return false }
        return s.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func isBase64(_ s: String) -> Bool {
        guard s.count >= 16, s.count % 4 == 0 else { return false }
        guard s.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil else { return false }
        return Data(base64Encoded: s) != nil
    }
}

extension NSColor {
    /// Parses `#RGB`, `#RRGGBB`, `RGB`, or `RRGGBB`. Returns nil otherwise.
    convenience init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        let cleaned = s.lowercased()
        guard cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        let r, g, b: CGFloat
        switch cleaned.count {
        case 3:
            let chars = Array(cleaned)
            guard let rv = UInt8(String([chars[0], chars[0]]), radix: 16),
                  let gv = UInt8(String([chars[1], chars[1]]), radix: 16),
                  let bv = UInt8(String([chars[2], chars[2]]), radix: 16) else { return nil }
            r = CGFloat(rv) / 255; g = CGFloat(gv) / 255; b = CGFloat(bv) / 255
        case 6:
            guard let value = UInt32(cleaned, radix: 16) else { return nil }
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >>  8) & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
