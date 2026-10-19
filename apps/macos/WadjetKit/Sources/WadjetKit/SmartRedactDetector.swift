import CoreGraphics
import Darwin
import Foundation
import Vision

/// Independently selectable Smart redact categories. Faces use the image API.
public enum SmartRedactCategory: String, CaseIterable, Codable, Sendable {
    case email, phoneNumber, link, streetAddress, cardNumber, iban, ipAddress, apiKey, face
}

/// One OCR line. Bounds use the caller's coordinate space and a left-to-right text axis.
/// `recognizeTextLines(in:)` supplies them from Vision; other callers supply boxes separately.
public struct SmartRedactTextLine: Equatable, Sendable {
    public var text: String
    public var bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// A match in an input line, with a UTF-16 range and proportional character bounds.
public struct SmartRedactMatch: Equatable, Sendable {
    public let category: SmartRedactCategory
    public let lineIndex: Int
    public let range: NSRange
    public let bounds: CGRect
}

/// UI-free detection over OCR lines. No screen capture or annotation mutation occurs here.
public struct SmartRedactDetector {
    private let dataDetector: NSDataDetector
    private let patterns: [(SmartRedactCategory, NSRegularExpression)]

    public init() throws {
        dataDetector = try NSDataDetector(types:
            NSTextCheckingResult.CheckingType.link.rawValue |
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
            NSTextCheckingResult.CheckingType.address.rawValue)
        // National lengths bound IBANs before adjacent currency/label fields. Never shorten
        // a failed checksum until it happens to pass. Lengths from the SWIFT IBAN registry:
        // https://www.swift.com/standards/data-standards/iban
        let ibanLengths = [
            (15, "NO"), (16, "BE"), (18, "DK FI AX FK FO GL NL SD"), (19, "MK SI"),
            (20, "AT BA EE KZ LT LU MN XK"), (21, "CH HR LI LV"),
            (22, "BG BH CR DE GB IM JE GG GE IE ME RS VA"), (23, "AE GI IL IQ OM SO TL"),
            (24, "AD CZ ES MD PK RO SA SE SK TN VG"), (25, "LY PT ST"), (26, "IS TR"),
            (27, "BI DJ FR GF GP MQ RE PF TF YT NC BL MF PM WF GR IT MC MR SM"),
            (28, "AL AZ BY CY DO GT HN HU LB NI PL SV"), (29, "BR EG PS QA UA"),
            (30, "JO KW MU YE"), (31, "MT SC"), (32, "LC"), (33, "RU"),
        ]
        let ibanPattern = ibanLengths.map { length, countries in
            let codes = countries.split(separator: " ").joined(separator: "|")
            return #"(?:\#(codes))[0-9]{2}(?: ?[A-Z0-9]){\#(length - 4)}"#
        }.joined(separator: "|")
        patterns = try [
            // A following MM/YY expiry is its own field, not another card digit group.
            (.cardNumber, #"(?<![\w-])(?:[0-9](?:[ -](?![0-9]{1,2}/))?){12,18}[0-9](?![\w-])"#),
            (.iban, #"\b(?:\#(ibanPattern))\b"#),
            // A final prose period is allowed only before a delimiter/end, never another component.
            (.ipAddress, #"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?=$|[^\w.]|\.(?=$|[\s,;!?)\]}]))|(?<![\w:])(?:[0-9A-Fa-f]*:){2,}[0-9A-Fa-f:.]*(?<!\.)(?=$|[^\w:.]|\.(?=$|[\s,;!?)\]}]))"#),
            (.apiKey, #"(?<![\w-])(?:sk-(?:proj-)?[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|gh[po]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bp]-[A-Za-z0-9-]{16,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35})(?![\w-])"#),
            (.apiKey, #"(?<![\w/+\-=])[A-Za-z0-9_+/\-=]{32,}(?![\w/+\-=])"#),
        ].map { category, pattern in (category, try NSRegularExpression(pattern: pattern)) }
    }

    /// Returns matches in input-line and character order. Overlapping categories are retained,
    /// except generic token guesses inside an already recognized match. Empty categories disables text detection.
    public func matches(
        in lines: [SmartRedactTextLine],
        categories: Set<SmartRedactCategory> = Set(SmartRedactCategory.allCases)
    ) -> [SmartRedactMatch] {
        var matches: [SmartRedactMatch] = []
        for (lineIndex, line) in lines.enumerated() where !line.text.isEmpty {
            let wholeLine = NSRange(line.text.startIndex..., in: line.text)
            let candidates = patterns.map { category, pattern in
                (category, pattern.matches(in: line.text, range: wholeLine))
            }
            var found: [(SmartRedactCategory, NSRange)] = []
            for result in dataDetector.matches(in: line.text, range: wholeLine) {
                let category: SmartRedactCategory
                switch result.resultType {
                case .link: category = result.url?.scheme == "mailto" ? .email : .link
                case .phoneNumber: category = .phoneNumber
                case .address: category = .streetAddress
                default: continue
                }
                // NSDataDetector treats grouped account/card digits as telephone numbers,
                // even when their checksum fails. Do not bypass the checksum that way.
                if category == .phoneNumber && candidates.prefix(2).contains(where: { category, results in
                    results.contains { candidate in
                        guard NSIntersectionRange(candidate.range, result.range).length > 0,
                              let range = Range(candidate.range, in: line.text) else { return false }
                        return category == .iban || line.text[range].filter(\.isNumber).count >= 16
                    }
                }) { continue }
                if categories.contains(category) { found.append((category, result.range)) }
            }
            for (index, entry) in candidates.enumerated() where categories.contains(entry.0) {
                let (category, results) = entry
                for result in results {
                    guard let range = Range(result.range, in: line.text) else { continue }
                    let value = String(line.text[range])
                    switch category {
                    case .cardNumber: guard Self.validCard(value) else { continue }
                    case .iban: guard Self.validIBAN(value) else { continue }
                    case .ipAddress: guard Self.validIP(value) else { continue }
                    case .apiKey where index == patterns.count - 1:
                        guard Self.isRandomToken(value),
                              !found.contains(where: { NSIntersectionRange($0.1, result.range).length > 0 })
                        else { continue }
                    default: break
                    }
                    found.append((category, result.range))
                }
            }
            for (category, range) in found.sorted(by: {
                if $0.1.location != $1.1.location { return $0.1.location < $1.1.location }
                return $0.0.rawValue < $1.0.rawValue
            }) {
                guard let characters = Range(range, in: line.text) else { continue }
                let start = line.text.distance(from: line.text.startIndex, to: characters.lowerBound)
                let width = line.text.distance(from: characters.lowerBound, to: characters.upperBound)
                let count = CGFloat(line.text.count)
                matches.append(SmartRedactMatch(
                    category: category, lineIndex: lineIndex, range: range,
                    bounds: CGRect(x: line.bounds.minX + CGFloat(start) / count * line.bounds.width,
                                   y: line.bounds.minY, width: CGFloat(width) / count * line.bounds.width,
                                   height: line.bounds.height)))
            }
        }
        return matches
    }

    /// Detects faces in an image supplied by the caller. Boxes are normalized to 0...1,
    /// with Vision's lower-left origin. The caller handles category selection and image orientation.
    public static func faceBoxes(in image: CGImage) async throws -> [CGRect] {
        let request = DetectFaceRectanglesRequest()
        return try await request.perform(on: image).map { $0.boundingBox.cgRect }
    }

    private static func validCard(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, item in
            let digit = item.offset.isMultiple(of: 2) ? item.element : item.element * 2
            return sum + (digit > 9 ? digit - 9 : digit)
        }
        return Set(digits).count > 1 && sum.isMultiple(of: 10)
    }

    private static func validIBAN(_ value: String) -> Bool {
        let compact = value.filter { $0 != " " }
        guard (15...34).contains(compact.count) else { return false }
        var remainder = 0
        for byte in (compact.dropFirst(4) + compact.prefix(4)).utf8 {
            if (65...90).contains(byte) {
                remainder = (remainder * 100 + Int(byte) - 55) % 97
            } else {
                remainder = (remainder * 10 + Int(byte) - 48) % 97
            }
        }
        return remainder == 1
    }

    private static func validIP(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    private static func isRandomToken(_ value: String) -> Bool {
        guard UUID(uuidString: value) == nil,
              value.contains(where: \.isNumber), value.contains(where: \.isLetter),
              !value.allSatisfy(\.isHexDigit)
        else { return false }
        let counts = Dictionary(grouping: value, by: { $0 }).values.map(\.count)
        let entropy = counts.reduce(0.0) { sum, count in
            let probability = Double(count) / Double(value.count)
            return sum - probability * log2(probability)
        }
        return entropy >= 4.2
    }
}
