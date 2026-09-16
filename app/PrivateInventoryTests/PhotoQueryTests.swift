import Foundation
@testable import PrivateInventory
import Testing

/// PhotoRecognitionModel chip query logic (ticket #26, D1b–D5b):
/// the significance filter, the chip building, the initial
/// selection and the query concatenation — pure functions (no OCR,
/// no network, no repository) — plus the async entry point
/// `applyRecognized(lines:)`.
struct PhotoQueryTests {
    /// Price tags, volumes and bare digit/whitespace lines are
    /// noise; lines with at least 4 letters stay significant —
    /// including lines that merely CONTAIN digits and claim text
    /// (the user deselects that, D3b).
    ///
    /// Given: the lines "1,95 €", "400 ml", "1234", "3€95", "   "
    /// (noise) and "Deo 250 ml", "schauma", "Repair & Pflege",
    /// "REPARATUR-SPRÜHPFLEGE",
    /// "STRAPAZIERTES UND TROCKENES HAAR" (significant)
    /// When: isSignificant is applied
    /// Then: the first five are NOT significant, the latter five
    /// are
    @MainActor
    @Test func isSignificantFilterDropsPriceVolumeAndDigitLines() {
        // Then: noise (D3b)
        #expect(!PhotoRecognitionModel.isSignificant("1,95 €"))
        #expect(!PhotoRecognitionModel.isSignificant("400 ml"))
        #expect(!PhotoRecognitionModel.isSignificant("1234"))
        #expect(!PhotoRecognitionModel.isSignificant("3€95"))
        #expect(!PhotoRecognitionModel.isSignificant("   "))
        // Then: significant (D3b)
        #expect(PhotoRecognitionModel.isSignificant("Deo 250 ml"))
        #expect(PhotoRecognitionModel.isSignificant("schauma"))
        #expect(PhotoRecognitionModel.isSignificant("Repair & Pflege"))
        #expect(PhotoRecognitionModel.isSignificant("REPARATUR-SPRÜHPFLEGE"))
        #expect(
            PhotoRecognitionModel.isSignificant("STRAPAZIERTES UND TROCKENES HAAR")
        )
    }

    /// The initial selection is the first TWO significant chips in
    /// reading order (D2b).
    ///
    /// Given: the five Schauma-label lines ["schauma",
    /// "Repair & Pflege", "REPARATUR-SPRÜHPFLEGE",
    /// "MIT KOKOS-EXTRAKT", "STRAPAZIERTES UND TROCKENES HAAR"]
    /// When: chips are built via makeChips and initialSelection is
    /// applied
    /// Then: the selection is exactly the ids of the first two
    /// chips
    @MainActor
    @Test func initialSelectionPicksFirstTwoSignificantChips() {
        // Given
        let lines = [
            RecognizedLine(text: "schauma", confidence: 0.9),
            RecognizedLine(text: "Repair & Pflege", confidence: 0.9),
            RecognizedLine(text: "REPARATUR-SPRÜHPFLEGE", confidence: 0.9),
            RecognizedLine(text: "MIT KOKOS-EXTRAKT", confidence: 0.9),
            RecognizedLine(text: "STRAPAZIERTES UND TROCKENES HAAR", confidence: 0.9)
        ]
        let chips = PhotoRecognitionModel.makeChips(from: lines)

        // When
        let selection = PhotoRecognitionModel.initialSelection(from: chips)

        // Then
        #expect(chips.count == 5)
        #expect(selection == Set([chips[0].id, chips[1].id]))
    }

    /// Leading noise lines are SKIPPED by the initial selection
    /// (D2b).
    ///
    /// Given: ["400 ml", "1234", "schauma", "Repair & Pflege",
    /// "MIT KOKOS-EXTRAKT"] (two noise lines lead)
    /// When: chips are built and initialSelection is applied
    /// Then: the selection is exactly chips 3 and 4 (index 2 and
    /// 3), NOT the first two chips
    @MainActor
    @Test func initialSelectionSkipsLeadingNoise() {
        // Given
        let lines = [
            RecognizedLine(text: "400 ml", confidence: 0.9),
            RecognizedLine(text: "1234", confidence: 0.9),
            RecognizedLine(text: "schauma", confidence: 0.9),
            RecognizedLine(text: "Repair & Pflege", confidence: 0.9),
            RecognizedLine(text: "MIT KOKOS-EXTRAKT", confidence: 0.9)
        ]
        let chips = PhotoRecognitionModel.makeChips(from: lines)

        // When
        let selection = PhotoRecognitionModel.initialSelection(from: chips)

        // Then
        #expect(selection == Set([chips[2].id, chips[3].id]))
    }

    /// Fewer than two significant lines → all significant chips are
    /// selected; no noise is force-selected (D2b).
    ///
    /// Given: ["1,95 €", "schauma"] (one noise, one significant)
    /// When: chips are built and initialSelection is applied
    /// Then: the selection is exactly the one significant chip
    @MainActor
    @Test func initialSelectionWithFewSignificantLinesSelectsAllSignificant() {
        // Given
        let lines = [
            RecognizedLine(text: "1,95 €", confidence: 0.9),
            RecognizedLine(text: "schauma", confidence: 0.9)
        ]
        let chips = PhotoRecognitionModel.makeChips(from: lines)

        // When
        let selection = PhotoRecognitionModel.initialSelection(from: chips)

        // Then
        #expect(selection == Set([chips[1].id]))
    }

    /// The query is the concatenation of the SELECTED chips' texts
    /// in CHIP order with single spaces; there is no length cap
    /// (D1b/D5b).
    ///
    /// Given: chips ["schauma", "Repair & Pflege",
    /// "MIT KOKOS-EXTRAKT"] with chip 1 and chip 3 selected
    /// When: query(from:selected:) is applied
    /// Then: "schauma MIT KOKOS-EXTRAKT" — an empty selection
    /// yields "", and a long selection is NOT truncated
    @MainActor
    @Test func queryIsConcatenationOfSelectedChipsInChipOrder() {
        // Given
        let chipA = QueryChip(text: "schauma")
        let chipB = QueryChip(text: "Repair & Pflege")
        let chipC = QueryChip(text: "MIT KOKOS-EXTRAKT")
        let chips = [chipA, chipB, chipC]

        // When
        let query = PhotoRecognitionModel.query(
            from: chips,
            selected: Set([chipA.id, chipC.id])
        )

        // Then: chip order, single spaces — chip 2 is skipped
        #expect(query == "schauma MIT KOKOS-EXTRAKT")
        #expect(PhotoRecognitionModel.query(from: chips, selected: []) == "")

        // Then (D5b): a concatenation over 120 chars is NOT
        // truncated
        let longA = QueryChip(text: String(repeating: "a", count: 60))
        let longB = QueryChip(text: String(repeating: "b", count: 60))
        let longC = QueryChip(text: String(repeating: "c", count: 60))
        let longChips = [longA, longB, longC]
        #expect(
            PhotoRecognitionModel.query(
                from: longChips,
                selected: Set(longChips.map(\.id))
            ) == String(repeating: "a", count: 60)
                + " "
                + String(repeating: "b", count: 60)
                + " "
                + String(repeating: "c", count: 60)
        )
    }

    /// `applyRecognized` builds the chips (noise included), seeds
    /// the selection with the first two significant chips (D2b) and
    /// runs exactly ONE first search with the seeded concatenation
    /// (D1b).
    ///
    /// Given: a model with a SearchRecorder and a TextRecognizerStub
    /// When: applyRecognized(lines:) with 4 lines (2 significant +
    /// 2 noise)
    /// Then: 4 chips, the two significant chips selected, and the
    /// recorder got exactly one query equal to model.searchQuery
    @MainActor
    @Test func applyRecognizedSeedsChipsSelectionAndSearches() async throws {
        // Given
        let searchRecorder = SearchRecorder()
        let inventory = try TestInventory()
        let model = PhotoRecognitionModel(
            scannedGTIN: "4066447599992",
            search: searchRecorder,
            binding: ProductBinding(repository: inventory.repository),
            recognizer: TextRecognizerStub(lines: [])
        )
        let lines = [
            RecognizedLine(text: "Balea MEN", confidence: 0.9),
            RecognizedLine(text: "Golden Intense Deospray", confidence: 0.9),
            RecognizedLine(text: "200 ml", confidence: 0.9),
            RecognizedLine(text: "1,95 €", confidence: 0.9)
        ]

        // When
        await model.applyRecognized(lines: lines)

        // Then: all 4 lines are chips (noise included, D1b)
        #expect(model.chips.count == 4)
        // Then: the two significant chips are selected (D2b)
        #expect(model.selected == Set([model.chips[0].id, model.chips[1].id]))
        // Then: exactly one search with the seeded concatenation
        let queries = await searchRecorder.queries
        #expect(queries.count == 1)
        #expect(queries[0] == model.searchQuery)
    }

    /// Toggling chips and adding a custom term change the search
    /// query (D1b/D4b); a whitespace-only term adds no chip.
    ///
    /// Given: seeded state from applyRecognized (the seeded query is
    /// "Balea MEN Golden Intense Deospray")
    /// When: toggleChip on a selected chip (off), toggleChip again
    /// (on), addCustomTerm("  Deospray  ") (trimmed, selected),
    /// then `await model.search()`
    /// Then: the recorder's query list shows the seeded query first
    /// and the updated query second (ending with "Deospray");
    /// addCustomTerm("   ") added no chip
    @MainActor
    @Test func toggleAndCustomTermChangeTheSearchQuery() async throws {
        // Given
        let searchRecorder = SearchRecorder()
        let inventory = try TestInventory()
        let model = PhotoRecognitionModel(
            scannedGTIN: "4066447599992",
            search: searchRecorder,
            binding: ProductBinding(repository: inventory.repository),
            recognizer: TextRecognizerStub()
        )
        await model.applyRecognized(lines: [
            RecognizedLine(text: "Balea MEN", confidence: 0.9),
            RecognizedLine(text: "Golden Intense Deospray", confidence: 0.9),
            RecognizedLine(text: "200 ml", confidence: 0.9),
            RecognizedLine(text: "1,95 €", confidence: 0.9)
        ])
        #expect(model.searchQuery == "Balea MEN Golden Intense Deospray")

        // When: the chip-off state → query without that chip's text
        let firstChip = model.chips[0]
        model.toggleChip(firstChip.id)
        #expect(model.searchQuery == "Golden Intense Deospray")
        // When: back on → with it
        model.toggleChip(firstChip.id)
        #expect(model.searchQuery == "Balea MEN Golden Intense Deospray")
        // When: the custom term is trimmed and SELECTED (D4b)
        model.addCustomTerm("  Deospray  ")
        #expect(model.searchQuery == "Balea MEN Golden Intense Deospray Deospray")
        // When: a whitespace-only term adds NO chip
        let chipCountBefore = model.chips.count
        model.addCustomTerm("   ")
        #expect(model.chips.count == chipCountBefore)

        // When
        await model.search()

        // Then: seeded query first, updated query second
        let queries = await searchRecorder.queries
        #expect(queries.count == 2)
        #expect(queries[0] == "Balea MEN Golden Intense Deospray")
        #expect(queries[1] == "Balea MEN Golden Intense Deospray Deospray")
    }
}

/// Records the queries and returns canned candidates (ADR-0006:
/// handwritten stub, no network).
private actor SearchRecorder: CatalogSearch {
    private(set) var queries: [String] = []
    private let candidates: [ResolvedProduct]

    init(candidates: [ResolvedProduct] = []) {
        self.candidates = candidates
    }

    func search(query: String) async throws -> [ResolvedProduct] {
        queries.append(query)
        return candidates
    }
}
