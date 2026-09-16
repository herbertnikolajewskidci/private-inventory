import Foundation
@testable import PrivateInventory
import Testing

/// ProductBinding (ticket #24, D5a/D6a/D8a): binding a scanned GTIN
/// to a user-confirmed product — create-or-reuse under the
/// candidate GTIN, alias for the scanned GTIN (ADR-0009), and
/// booking of ALL open queue rows of the scanned GTIN.
struct ProductBindingTests {
    private let gtinA = "4000000000099"
    private let gtinB = "4000000000098"
    private let gtinC = "4000000000097"
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// Records one queued scan for the test setup.
    private func recordScan(
        _ inventory: TestInventory,
        gtin: String,
        locationID: UUID,
        quantity: Int = 1
    ) throws {
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtin,
                locationID: locationID,
                quantity: quantity,
                createdAt: baseTime
            )
        )
    }

    /// Manual form (D6a) with no edited GTIN: the product is
    /// created under the SCANNED GTIN with source .manual and all
    /// open rows of the GTIN are booked.
    ///
    /// Given: two queued scans of the scanned GTIN at the Keller
    /// (quantity 1 each)
    /// When: bind(scannedGTIN: A, productGTIN: nil, ...)
    /// Then: a product under A with source .manual, the Keller stock
    /// is 2 and the queue is empty
    @Test func manualEntryCreatesProductUnderScannedGTINAndBooksAllRows() throws {
        // Given: two queued scans of A at the Keller
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        try recordScan(inventory, gtin: gtinA, locationID: cellar.id)
        try recordScan(inventory, gtin: gtinA, locationID: cellar.id)

        // When
        let (product, bookedRows) = try ProductBinding(repository: inventory.repository).bind(
            scannedGTIN: gtinA,
            productGTIN: nil,
            name: "Balea Deo",
            brand: "Balea",
            imageURL: nil
        )

        // Then
        #expect(product.gtin == gtinA)
        #expect(product.source == .manual)
        let stock = try #require(
            try inventory.repository.fetchStockLevel(
                productID: product.id,
                locationID: cellar.id
            )
        )
        #expect(stock.quantity == 2)
        #expect(bookedRows == 2)
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// Photo candidate (D4a) with a KNOWN candidate GTIN: the
    /// existing product is reused (no second product), the scanned
    /// GTIN becomes its alias (ADR-0009), and every row of the
    /// scanned GTIN is booked at its own location.
    ///
    /// Given: a product under the candidate GTIN B (source .search)
    /// and two rows under the scanned GTIN A (one Keller, one
    /// Vorratsschrank)
    /// When: bind(scannedGTIN: A, productGTIN: B, ...)
    /// Then: fetchProduct(gtin: A) returns the SAME product (no
    /// duplicate), the stock is 1 at BOTH locations, the queue is
    /// empty
    @Test func photoCandidateReusesExistingProductAndCreatesAlias() throws {
        // Given: a product under B and two rows under A
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let pantry = try #require(try inventory.pantry())
        let existing = try inventory.repository.createProduct(
            Product(
                gtin: gtinB,
                name: "Deospray Golden Intense, 150 ml",
                brand: "Balea MEN",
                imageURL: nil,
                source: .search
            )
        )
        try recordScan(inventory, gtin: gtinA, locationID: cellar.id)
        try recordScan(inventory, gtin: gtinA, locationID: pantry.id)

        // When
        let (product, bookedRows) = try ProductBinding(repository: inventory.repository).bind(
            scannedGTIN: gtinA,
            productGTIN: gtinB,
            name: existing.name,
            brand: existing.brand,
            imageURL: nil
        )

        // Then: the scanned GTIN resolves to the SAME product
        #expect(product.id == existing.id)
        let viaAlias = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        #expect(viaAlias.id == existing.id)
        // And both rows were booked at their own locations
        let cellarStock = try #require(
            try inventory.repository.fetchStockLevel(
                productID: existing.id,
                locationID: cellar.id
            )
        )
        let pantryStock = try #require(
            try inventory.repository.fetchStockLevel(
                productID: existing.id,
                locationID: pantry.id
            )
        )
        #expect(cellarStock.quantity == 1)
        #expect(pantryStock.quantity == 1)
        #expect(bookedRows == 2)
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// Photo candidate (D4a) with an UNKNOWN candidate GTIN: the
    /// product is created under the candidate GTIN (source .manual,
    /// D8a) and the scanned GTIN becomes its alias.
    ///
    /// Given: rows under the scanned GTIN A and no product under the
    /// candidate GTIN B
    /// When: bind(scannedGTIN: A, productGTIN: B, ...)
    /// Then: a product under B with source .manual,
    /// fetchProduct(gtin: A) returns that product (alias), the stock
    /// is booked and the queue is empty
    @Test func photoCandidateCreatesProductAndAliasWhenCandidateUnknown() throws {
        // Given: two rows under A, no product under B
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let pantry = try #require(try inventory.pantry())
        try recordScan(inventory, gtin: gtinA, locationID: cellar.id)
        try recordScan(inventory, gtin: gtinA, locationID: pantry.id)

        // When
        let (product, bookedRows) = try ProductBinding(repository: inventory.repository).bind(
            scannedGTIN: gtinA,
            productGTIN: gtinB,
            name: "Deospray Golden Intense, 150 ml",
            brand: "Balea MEN",
            imageURL: nil
        )

        // Then: created under B as the user's curated truth
        #expect(product.gtin == gtinB)
        #expect(bookedRows == 2)
        #expect(product.source == .manual)
        // The scanned GTIN resolves to it via the alias
        let viaAlias = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        #expect(viaAlias.id == product.id)
        // Both rows booked
        #expect(
            try inventory.repository.fetchStockLevel(
                productID: product.id,
                locationID: cellar.id
            )?.quantity == 1
        )
        #expect(
            try inventory.repository.fetchStockLevel(
                productID: product.id,
                locationID: pantry.id
            )?.quantity == 1
        )
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// Edited form GTIN of an EXISTING other product: the scanned
    /// GTIN is already the primary GTIN of its own product, so it
    /// can never become an alias of the other one — the binding is
    /// refused and the queue stays untouched.
    ///
    /// Given: existing products under the scanned GTIN A and under
    /// the edited GTIN C, two rows under A
    /// When: bind(scannedGTIN: A, productGTIN: C, ...)
    /// Then: InventoryError.duplicateGTIN is thrown, the queue still
    /// has both rows, no alias exists (A still resolves to its own
    /// product)
    @Test func editedGTINOfExistingOtherProductThrowsDuplicateGTIN() throws {
        // Given: a product under A, a product under C, rows under A
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let pantry = try #require(try inventory.pantry())
        let productA = try inventory.repository.createProduct(
            Product(
                gtin: gtinA,
                name: "Bestehendes Produkt",
                brand: "Balea",
                imageURL: nil,
                source: .manual
            )
        )
        _ = try inventory.repository.createProduct(
            Product(
                gtin: gtinC,
                name: "Anderes Produkt",
                brand: "Balea",
                imageURL: nil,
                source: .manual
            )
        )
        try recordScan(inventory, gtin: gtinA, locationID: cellar.id)
        try recordScan(inventory, gtin: gtinA, locationID: pantry.id)

        // When/Then: A is a primary GTIN of another product
        #expect(throws: InventoryError.duplicateGTIN) {
            try ProductBinding(repository: inventory.repository).bind(
                scannedGTIN: gtinA,
                productGTIN: gtinC,
                name: "Anderes Produkt",
                brand: "Balea",
                imageURL: nil
            )
        }

        // The queue is untouched and no alias was created
        let scans = try inventory.repository.fetchUnresolvedScans()
        #expect(scans.count == 2)
        #expect(scans.allSatisfy { $0.gtin == gtinA })
        let stillA = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        #expect(stillA.id == productA.id)
    }
}
