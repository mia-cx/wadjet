import Foundation
import Vision

/// Vision OCR over an image file: accurate recognition with language
/// correction, observations joined with newlines. Used to index Screenshots'
/// text for History (#27 search); callers log failures and move on — OCR is
/// never worth breaking a capture.
public func recognizeText(in file: URL) async throws -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let observations = try await request.perform(on: file)
    return observations
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}
