import Foundation
import Observation
import UIKit

/// The photo-recognition flow state (ticket #24, D3a): OCR runs
/// first, then the user edits the search query and confirms a
/// candidate. Booking goes through `ProductBinding` (one step:
/// alias + all queue rows).
@MainActor
@Observable
final class PhotoRecognitionModel {
    enum Phase: Equatable {
        /// Waiting for a photo (camera or library).
        case idle
        case recognizing
        /// Candidates found; the query is editable.
        case candidates(matches: [ResolvedProduct])
        /// The search answered with zero usable candidates.
        case noMatches
        /// The product is bound; all rows of the GTIN are booked.
        case booked(product: Product, bookedRows: Int)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    /// The editable search query (D3a): prefilled from the OCR
    /// text, the user corrects OCR errors here.
    var searchQuery: String = ""

    private let scannedGTIN: String
    private let recognizer: any TextRecognizer
    private let search: any CatalogSearch
    private let binding: ProductBinding

    init(
        scannedGTIN: String,
        search: any CatalogSearch,
        binding: ProductBinding,
        recognizer: any TextRecognizer
    ) {
        self.scannedGTIN = scannedGTIN
        self.search = search
        self.binding = binding
        self.recognizer = recognizer
    }

    /// Builds the initial query from OCR lines (pure, testable):
    /// drop lines that are pure digits/whitespace or shorter than
    /// 4 characters, join the rest with single spaces, cap at 120
    /// characters. OCR errors are fine — the user edits the query
    /// (D3a).
    static func searchQuery(from lines: [RecognizedLine]) -> String {
        let usable = lines.compactMap { line -> String? in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { return nil }
            guard !trimmed.allSatisfy({ $0.isNumber || $0.isWhitespace }) else {
                return nil
            }
            return trimmed
        }
        return String(usable.joined(separator: " ").prefix(120))
    }

    /// OCR + first search: sets `.recognizing`, runs the
    /// recognizer (with the image's orientation, CodeRabbit),
    /// builds the query, then `search()`. A thrown error (or a
    /// nil/CGImage-less image) → `.failed(message:)`.
    func recognize(image: UIImage?) async {
        phase = .recognizing
        guard let image, let cgImage = image.cgImage else {
            phase = .failed(message: String(localized: "OCR fehlgeschlagen."))
            return
        }
        do {
            let lines = try await recognizer.recognize(
                in: cgImage,
                orientation: image.visionOrientation
            )
            searchQuery = Self.searchQuery(from: lines)
            await search()
        } catch {
            phase = .failed(message: String(localized: "OCR fehlgeschlagen."))
        }
    }

    /// Re-runs the catalog search with the current `searchQuery`.
    /// Zero usable candidates → `.noMatches`; else `.candidates`.
    /// Errors → `.failed(message:)`.
    func search() async {
        do {
            let matches = try await search.search(query: searchQuery)
            phase = matches.isEmpty ? .noMatches : .candidates(matches: matches)
        } catch {
            phase = .failed(message: String(localized: "Fehler beim Suchen."))
        }
    }

    /// Confirms a photo candidate: binds the scanned GTIN to the
    /// candidate's product (create-or-reuse under the candidate's
    /// OWN gtin + alias for the scanned GTIN) and books all open
    /// queue rows (D5a). Sets `.booked` on success and
    /// `.failed(message:)` on throw (the throw still propagates to
    /// the view).
    func confirm(candidate: ResolvedProduct) throws {
        do {
            // The binding transaction reports the authoritative
            // count (a pre-count could race a concurrent queue run,
            // CodeRabbit).
            let (product, bookedRows) = try binding.bind(
                scannedGTIN: scannedGTIN,
                productGTIN: candidate.gtin,
                name: candidate.name,
                brand: candidate.brand,
                imageURL: candidate.imageURL
            )
            phase = .booked(product: product, bookedRows: bookedRows)
        } catch {
            phase = .failed(message: String(localized: "Fehler beim Buchen."))
            throw error
        }
    }
}
