import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct SmartRedactDetectorTests {
    struct Fixture: Sendable {
        var text: String
        var category: SmartRedactCategory?
    }

    // Proves each supported category is found, while invalid checksums and token near misses stay clear.
    @Test(arguments: [
        Fixture(text: "mia@example.com", category: .email),
        Fixture(text: "+1 (415) 555-2671", category: .phoneNumber),
        Fixture(text: "https://example.com/private", category: .link),
        Fixture(text: "1 Infinite Loop, Cupertino, CA 95014", category: .streetAddress),
        Fixture(text: "4111 1111 1111 1111", category: .cardNumber),
        Fixture(text: "4111-1111-1111-1111", category: .cardNumber),
        Fixture(text: "4111 1111 1111 1112", category: nil),
        Fixture(text: "0000000000000000", category: nil),
        Fixture(text: "GB82 WEST 1234 5698 7654 32", category: .iban),
        Fixture(text: "NL91ABNA0417164300", category: .iban),
        Fixture(text: "GB83 WEST 1234 5698 7654 32", category: nil),
        Fixture(text: "192.168.1.24", category: .ipAddress),
        Fixture(text: "256.168.1.24", category: nil),
        Fixture(text: "2001:db8::1", category: .ipAddress),
        Fixture(text: "::1", category: .ipAddress),
        Fixture(text: "::ffff:192.0.2.128", category: .ipAddress),
        Fixture(text: "2001:db8:::1", category: nil),
        Fixture(text: "sk-abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "sk_live_" + "abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "ghp_abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "gho_abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "github_pat_abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "xoxb-" + "123456789012-abcdefghijklmnop", category: .apiKey),
        Fixture(text: "xoxp-" + "123456789012-abcdefghijklmnop", category: .apiKey),
        Fixture(text: "AKIAIOSFODNN7EXAMPLE", category: .apiKey),
        Fixture(text: "AIzaSyA1234567890abcdefghijklmnopqrstuvwx", category: .apiKey),
        Fixture(text: "aZ9mK2pR7xT4vN8qL1wE6cY3uI5oP0sD", category: .apiKey),
        Fixture(text: "pneumonoultramicroscopicsilicovolcanoconiosis", category: nil),
        Fixture(text: "550e8400-e29b-41d4-a716-446655440000", category: nil),
        Fixture(text: "#ff0000 #00ff00 #0000ff #abcdef #123456", category: nil),
        Fixture(text: "0123456789abcdef0123456789abcdef0123456789abcdef", category: nil),
        Fixture(text: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1", category: nil),
        Fixture(text: "sk-short", category: nil),
    ])
    func recognizedCategories(fixture: Fixture) throws {
        let bounds = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05)
        let detector = try SmartRedactDetector()
        let matches = detector.matches(in: [.init(text: fixture.text, bounds: bounds)])
        #expect(matches.map(\.category) == fixture.category.map { [$0] } ?? [])
        for match in matches {
            #expect(match.bounds == bounds)
            #expect(match.range == NSRange(location: 0, length: fixture.text.utf16.count))
        }
    }

    // Proves sub-line boxes use grapheme offsets, keep line coordinates, and honor category switches.
    @Test func boxesAndCategorySelection() throws {
        let detector = try SmartRedactDetector()
        let lines = [
            SmartRedactTextLine(text: "👩🏽‍💻 e\u{301} mia@example.com end", bounds: CGRect(x: 10, y: 50, width: 230, height: 20)),
            SmartRedactTextLine(text: "IP 192.168.1.24 ok", bounds: CGRect(x: 0, y: 80, width: 180, height: 10)),
            SmartRedactTextLine(text: "", bounds: .zero),
        ]
        let matches = detector.matches(in: lines, categories: [.email, .ipAddress])
        #expect(matches.map(\.category) == [.email, .ipAddress])
        #expect(matches.map(\.lineIndex) == [0, 1])
        #expect(matches.map(\.bounds) == [
            CGRect(x: 50, y: 50, width: 150, height: 20),
            CGRect(x: 30, y: 80, width: 120, height: 10),
        ])
        #expect(matches.first?.range == NSRange(location: 11, length: 15))
        #expect(detector.matches(in: lines, categories: [.cardNumber]).isEmpty)
        #expect(detector.matches(in: lines, categories: []).isEmpty)
    }

    // Proves face detection can consume a caller-owned image without screen access.
    @Test func blankImageHasNoFaces() async throws {
        let context = try #require(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try #require(context.makeImage())
        #expect(try await SmartRedactDetector.faceBoxes(in: image).isEmpty)
    }
}
