import Foundation
@testable import PrivateInventory
import Testing

/// GTIN aliases at the repository layer (ADR-0009, ticket #24): the
/// alias round-trip through fetchProduct(gtin:) and the uniqueness
/// rules — a GTIN is either the primary GTIN of a Product or the
/// alias of exactly ONE product, never both and never two.
///
/// Kept in its own file: `GRDBInventoryRepositoryTests` is at the
/// 400-line SwiftLint file length limit.
struct GTINAliasRepositoryTests {
    /// fetchProduct(gtin:) resolves an alias GTIN to the product it
    /// is bound to (round-trip through the database).
    ///
    /// Given: a product under GTIN B and an alias A -> B
    /// When: fetchProduct(gtin: A)
    /// Then: the aliased product B comes back
    @Test func aliasRoundtripFetchProductResolvesAliasGTIN() throws {
        // Given: a product under B and an alias A -> B
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Deo")
        )
        try inventory.repository.createGTINAlias(gtin: "4000000000003", productID: product.id)

        // When: fetched via the alias GTIN
        let fetched = try #require(
            try inventory.repository.fetchProduct(gtin: "4000000000003")
        )

        // Then: the aliased product comes back
        #expect(fetched == product)
    }

    /// createGTINAlias() refuses the primary GTIN of a Product: a
    /// primary GTIN is never an alias (ADR-0009).
    ///
    /// Given: two products
    /// When: createGTINAlias(gtin: first.gtin, productID: second.id)
    /// Then: InventoryError.duplicateGTIN is thrown
    @Test func createGTINAliasRejectsPrimaryGTINOfAnotherProduct() throws {
        // Given: two products
        let inventory = try TestInventory()
        let first = try inventory.repository.createProduct(TestInventory.product())
        let second = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Quark")
        )

        // When/Then: a primary GTIN can never be an alias
        #expect(throws: InventoryError.duplicateGTIN) {
            try inventory.repository.createGTINAlias(gtin: first.gtin, productID: second.id)
        }
    }

    /// createGTINAlias() refuses a GTIN that is already an alias of
    /// a DIFFERENT product (a GTIN resolves to exactly one product).
    ///
    /// Given: two products and an alias A -> first
    /// When: createGTINAlias(gtin: A, productID: second.id)
    /// Then: InventoryError.duplicateGTIN is thrown
    @Test func createGTINAliasRejectsGTINOfDifferentAlias() throws {
        // Given: two products and an alias A -> first
        let inventory = try TestInventory()
        let first = try inventory.repository.createProduct(TestInventory.product())
        let second = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Quark")
        )
        try inventory.repository.createGTINAlias(gtin: "4000000000003", productID: first.id)

        // When/Then: the same GTIN cannot alias a different product
        #expect(throws: InventoryError.duplicateGTIN) {
            try inventory.repository.createGTINAlias(gtin: "4000000000003", productID: second.id)
        }
    }

    /// createProduct() refuses a GTIN that is already an alias (an
    /// alias GTIN can never become a primary GTIN, ADR-0009).
    ///
    /// Given: a product under B and an alias A -> B
    /// When: createProduct(gtin: A, ...)
    /// Then: InventoryError.duplicateGTIN is thrown
    @Test func createProductRejectsAliasGTIN() throws {
        // Given: a product under B and an alias A -> B
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Deo")
        )
        try inventory.repository.createGTINAlias(gtin: "4000000000003", productID: product.id)

        // When/Then: the alias GTIN cannot become a primary GTIN
        #expect(throws: InventoryError.duplicateGTIN) {
            try inventory.repository.createProduct(
                TestInventory.product(gtin: "4000000000003", name: "Sonstiges")
            )
        }
    }

    /// createGTINAlias() validates its parent: no product under the
    /// id means InventoryError.missingParent (the repository
    /// validates parents itself, ADR-0005).
    ///
    /// Given: a fresh database (the product does not exist)
    /// When: createGTINAlias(gtin:, productID: unknown)
    /// Then: InventoryError.missingParent is thrown
    @Test func createGTINAliasWithoutProductThrowsMissingParent() throws {
        // Given: a fresh database (the product does not exist)
        let inventory = try TestInventory()

        // When/Then
        #expect(throws: InventoryError.missingParent) {
            try inventory.repository.createGTINAlias(gtin: "4000000000003", productID: UUID())
        }
    }

    /// bindGTIN() reuses the product an alias GTIN belongs to: a
    /// candidate GTIN that is itself an alias resolves to the SAME
    /// product (no second product, CodeRabbit atomic-bind follow-up
    /// coverage for the alias-of-target path).
    ///
    /// Given: a product under GTIN B and an alias A -> B
    /// When: bindGTIN(scannedGTIN: X, product: Product under the
    /// alias GTIN A)
    /// Then: the SAME product under B comes back, X is its second
    /// alias, and A still resolves to the product
    @Test func bindGTINReusesProductWhenTargetGTINIsAnAlias() throws {
        // Given: a product under B, alias A -> B
        let inventory = try TestInventory()
        let product = try inventory.repository.createProduct(
            TestInventory.product(gtin: "4000000000002", name: "Deo")
        )
        try inventory.repository.createGTINAlias(
            gtin: "4000000000003",
            productID: product.id
        )

        // When: binding a scanned GTIN to the alias GTIN A
        let (bound, bookedRows) = try inventory.repository.bindGTIN(
            scannedGTIN: "4000000000009",
            product: TestInventory.product(gtin: "4000000000003", name: "Deo")
        )

        // Then: the aliased product under B, two aliases now
        #expect(bound.id == product.id)
        #expect(bound.gtin == "4000000000002")
        #expect(bookedRows == 0)
        let viaA = try #require(
            try inventory.repository.fetchProduct(gtin: "4000000000003")
        )
        let viaX = try #require(
            try inventory.repository.fetchProduct(gtin: "4000000000009")
        )
        #expect(viaA.id == product.id)
        #expect(viaX.id == product.id)
    }
}
