import CoreGraphics
import Foundation
import Vision

/// One line of text recognized on a product label (photo
/// recognition, ticket #24).
struct RecognizedLine: Equatable, Sendable {
    let id: UUID
    let text: String
    /// Vision confidence, 0.0 ... 1.0.
    let confidence: Double

    init(text: String, confidence: Double) {
        id = UUID()
        self.text = text
        self.confidence = confidence
    }
}

/// The on-device OCR seam (ADR-0006, like `Scanner`): tests and the
/// simulator run against a stub; the live implementation uses the
/// Vision text recognition. Fully on-device, no network (ADR-0004).
protocol TextRecognizer: Sendable {
    /// Recognizes text lines in the image, in reading order.
    func recognize(in image: CGImage) async throws -> [RecognizedLine]
}

/// The live on-device implementation (Vision, ticket #24).
struct VisionTextRecognizer: TextRecognizer {
    /// Lines below this Vision confidence are dropped (OCR noise).
    static let minimumConfidence = 0.3

    func recognize(in image: CGImage) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "de-DE"].compactMap {
            Locale.Language(identifier: $0)
        }
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first }
            .filter { Double($0.confidence) >= Self.minimumConfidence }
            .map { RecognizedLine(text: $0.string, confidence: Double($0.confidence)) }
    }
}

/// The test/simulator stand-in (ADR-0006): returns canned lines and
/// records its calls.
actor TextRecognizerStub: TextRecognizer {
    private(set) var callCount = 0
    private var lines: [RecognizedLine]

    init(lines: [RecognizedLine] = []) {
        self.lines = lines
    }

    func setLines(_ lines: [RecognizedLine]) {
        self.lines = lines
    }

    func recognize(in _: CGImage) async throws -> [RecognizedLine] {
        callCount += 1
        return lines
    }
}
