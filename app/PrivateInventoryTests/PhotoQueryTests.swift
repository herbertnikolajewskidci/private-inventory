import Foundation
@testable import PrivateInventory
import Testing

/// PhotoRecognitionModel.searchQuery(from:) (ticket #24, D3a):
/// building the initial search query from recognized OCR lines — a
/// pure function (no OCR, no network, no repository).
struct PhotoQueryTests {
    /// Short lines and lines that are pure digits/whitespace
    /// (sizes, barcodes) are dropped; the remaining lines are joined
    /// with single spaces.
    ///
    /// Given: the lines ["Balea MEN", "150", "1234",
    /// "Golden Intense Deospray"]
    /// When: searchQuery(from:) is applied
    /// Then: "Balea MEN Golden Intense Deospray" — and an empty line
    /// list yields an empty query
    @MainActor
    @Test func searchQueryDropsShortAndDigitOnlyLines() {
        // Given
        let lines = [
            RecognizedLine(text: "Balea MEN", confidence: 0.9),
            RecognizedLine(text: "150", confidence: 0.9),
            RecognizedLine(text: "1234", confidence: 0.9),
            RecognizedLine(text: "Golden Intense Deospray", confidence: 0.9)
        ]

        // When
        let query = PhotoRecognitionModel.searchQuery(from: lines)

        // Then
        #expect(query == "Balea MEN Golden Intense Deospray")
        #expect(PhotoRecognitionModel.searchQuery(from: []) == "")
    }
}
