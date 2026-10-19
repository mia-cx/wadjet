import Foundation
import Vision

/// the OCR setup History indexing and Smart Redact share: accurate, with
/// language correction
private func textRequest() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    return request
}

/// Vision OCR over an image file: accurate recognition with language
/// correction, observations joined with newlines. Used to index Screenshots'
/// text for History (#27 search); callers log failures and move on — OCR is
/// never worth breaking a capture.
public func recognizeText(in file: URL) async throws -> String {
    let observations = try await textRequest().perform(on: file)
    return observations
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

/// One OCR line: the text candidate plus the line's normalized (0...1,
/// lower-left) box. Keeps the RecognizedText so a sub-range's own box stays
/// available — Smart Redact's matched ranges.
public struct RecognizedLine: Sendable {
    public let line: SmartRedactTextLine
    let text: RecognizedText
    /// the range's normalized box, or nil when Vision reports none
    public func bounds(of range: NSRange) -> CGRect? {
        guard let range = Range(range, in: line.text) else { return nil }
        return text.boundingBox(for: range)?.boundingBox.cgRect
    }
}

/// Vision OCR over an image: one RecognizedLine per line, boxes normalized
/// to 0...1 with a lower-left origin.
public func recognizeTextLines(in image: CGImage) async throws -> [RecognizedLine] {
    try await textRequest().perform(on: image).compactMap { observation in
        observation.topCandidates(1).first.map {
            RecognizedLine(line: SmartRedactTextLine(text: $0.string, bounds: observation.boundingBox.cgRect),
                           text: $0)
        }
    }
}
