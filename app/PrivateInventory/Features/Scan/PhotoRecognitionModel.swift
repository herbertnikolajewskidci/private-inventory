import Foundation
import Observation
import UIKit

/// The photo-recognition flow state (ticket #24, D3a; ticket #26,
/// D1b): OCR runs first, the recognized lines become toggleable
/// chips, the search query is the concatenation of the SELECTED
/// chips (single source of truth), the user confirms a candidate.
/// Booking goes through `ProductBinding` (one step: alias + all
/// queue rows).
@MainActor
@Observable
final class PhotoRecognitionModel {
    enum Phase: Equatable {
        /// Waiting for a photo (camera or library).
        case idle
        case recognizing
        /// Candidates found; the query is adjustable via chips.
        case candidates(matches: [ResolvedProduct])
        /// The search answered with zero usable candidates.
        case noMatches
        /// The product is bound; all rows of the GTIN are booked.
        case booked(product: Product, bookedRows: Int)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    /// The recognized OCR lines (plus user-added terms) as chips
    /// (ticket #26, D1b); the source of truth for the query.
    private(set) var chips: [QueryChip] = []
    /// The currently selected chip ids (ticket #26, D1b/D2b).
    private(set) var selected: Set<UUID> = []
    /// The search query: the concatenation of the SELECTED chips
    /// in chip order (ticket #26, D1b/D5b — no length cap).
    var searchQuery: String {
        Self.query(from: chips, selected: selected)
    }

    private let scannedGTIN: String
    private let recognizer: any TextRecognizer
    private let search: any CatalogSearch
    private let binding: ProductBinding
    /// Counts the started searches; a response of an OVERLAPPED
    /// search is discarded so a slow older request cannot overwrite
    /// the state of a newer one (CodeRabbit).
    private var searchGeneration = 0

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

    /// A line is significant when at least 4 letters remain after
    /// dropping digits, whitespace and punctuation (ticket #26,
    /// D3b): a LOOSE noise filter — price tags ("1,95 €"), volumes
    /// ("400 ml") and bare barcodes ("1234") are noise; lines that
    /// merely CONTAIN digits ("Deo 250 ml") stay significant. Claim
    /// text is not filter noise (the user deselects it, D3b).
    static func isSignificant(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 4
    }

    /// Builds the chip list from OCR lines in reading order (ticket
    /// #26, D1b). Texts are trimmed; empty lines are skipped. Noise
    /// lines are INCLUDED as chips — the heuristic only decides the
    /// preselection (D2b), never silently removes a line.
    static func makeChips(from lines: [RecognizedLine]) -> [QueryChip] {
        lines.compactMap { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return QueryChip(text: trimmed)
        }
    }

    /// Initial selection: the first TWO significant chips in reading
    /// order (ticket #26, D2b). Real-label check (Schauma front
    /// photo): "schauma" + "Repair & Pflege" selected. Fewer
    /// significant chips → all of them selected.
    static func initialSelection(from chips: [QueryChip]) -> Set<UUID> {
        let significant = chips.filter { isSignificant($0.text) }
        return Set(significant.prefix(2).map(\.id))
    }

    /// The query: the selected chips' texts, in chip order, joined
    /// with single spaces. NO length cap anymore (D5b).
    static func query(from chips: [QueryChip], selected: Set<UUID>) -> String {
        chips
            .filter { selected.contains($0.id) }
            .map(\.text)
            .joined(separator: " ")
    }

    /// The OCR post-processing path (ticket #26): builds the chips,
    /// seeds the selection (D2b) and runs the first search with it.
    func applyRecognized(lines: [RecognizedLine]) async {
        chips = Self.makeChips(from: lines)
        selected = Self.initialSelection(from: chips)
        await search()
    }

    /// OCR + first search: sets `.recognizing`, runs the
    /// recognizer (with the image's orientation, CodeRabbit),
    /// then `applyRecognized` (chips + seeded selection + search).
    /// A thrown error (or a nil/CGImage-less image) →
    /// `.failed(message:)`.
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
            await applyRecognized(lines: lines)
        } catch {
            phase = .failed(message: String(localized: "OCR fehlgeschlagen."))
        }
    }

    /// Re-runs the catalog search with the current `searchQuery`.
    /// Zero usable candidates → `.noMatches`; else `.candidates`.
    /// Errors → `.failed(message:)`.
    func search() async {
        searchGeneration += 1
        let myGeneration = searchGeneration
        do {
            let matches = try await search.search(query: searchQuery)
            guard myGeneration == searchGeneration else {
                // A newer search is in flight; this response is stale.
                return
            }
            phase = matches.isEmpty ? .noMatches : .candidates(matches: matches)
        } catch {
            guard myGeneration == searchGeneration else { return }
            phase = .failed(message: String(localized: "Fehler beim Suchen."))
        }
    }

    /// Toggles one chip's selection (D1b). Does NOT search — the
    /// user runs "Suchen" explicitly.
    func toggleChip(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    /// Adds a user-typed term as a SELECTED custom chip (D4b).
    /// ALL whitespace is trimmed (including newlines, CodeRabbit:
    /// a newline-only term must never become a chip); an empty/
    /// whitespace-only term is ignored. Does NOT run a search.
    func addCustomTerm(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chip = QueryChip(text: trimmed, isCustom: true)
        chips.append(chip)
        selected.insert(chip.id)
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
