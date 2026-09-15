import Foundation
@testable import PrivateInventory
import Testing

/// Queue re-resolution (ADR-0003, ticket #14): UnresolvedScans are
/// booked into the inventory as soon as the lookup chain can resolve
/// their GTIN, and stay in the queue otherwise.
struct QueueResolutionTests {
    private let gtinA = "4000000000001"
    private let gtinB = "4000000000002"
    private let gtinC = "4000000000003"
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fresh in-memory inventory plus a lookup wired to it.
    private func makeLookup(
        sources: [StubCatalogSource]
    ) throws -> (inventory: TestInventory, lookup: CatalogLookup) {
        let inventory = try TestInventory()
        let cache = GRDBCatalogCache(database: inventory.database)
        let lookup = CatalogLookup(
            cache: cache,
            sources: sources,
            repository: inventory.repository
        )
        return (inventory, lookup)
    }

    /// A queued scan whose GTIN the chain can resolve is booked
    /// (Product created, stock at the scan's location) and removed
    /// from the queue.
    ///
    /// Given: a queued scan of three units at the Keller and a
    /// resolving source
    /// When: resolvePendingScans() runs
    /// Then: it returns 1, the Product exists with the resolved data,
    /// the Keller stock is 3 and the queue is empty
    @Test func resolvableScanIsBookedAndRemovedFromQueue() async throws {
        // Given
        let (inventory, lookup) = try makeLookup(sources: [
            StubCatalogSource(
                name: "mcp",
                outcomes: [
                    .product(stubProduct(gtin: gtinA, name: "Mehl", brand: "Mühle"))
                ]
            )
        ])
        let cellar = try #require(try inventory.cellar())
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinA,
                locationID: cellar.id,
                quantity: 3,
                createdAt: baseTime
            )
        )

        // When
        let count = try await lookup.resolvePendingScans()

        // Then
        #expect(count == 1)
        let product = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        #expect(product.name == "Mehl")
        #expect(product.brand == "Mühle")
        #expect(product.source == .mcp)
        let stock = try #require(
            try inventory.repository.fetchStockLevel(
                productID: product.id,
                locationID: cellar.id
            )
        )
        #expect(stock.quantity == 3)
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// A queued scan whose GTIN no source can resolve stays in the
    /// queue; nothing is created.
    ///
    /// Given: a queued scan and sources that all answer not-found
    /// When: resolvePendingScans() runs
    /// Then: it returns 0, the scan is still in the queue and no
    /// Product exists
    @Test func unresolvableScanStaysInQueue() async throws {
        // Given
        let (inventory, lookup) = try makeLookup(sources: [
            StubCatalogSource(name: "mcp", outcomes: [.notFound]),
            StubCatalogSource(name: "search", outcomes: [.notFound])
        ])
        let cellar = try #require(try inventory.cellar())
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinA,
                locationID: cellar.id,
                quantity: 1,
                createdAt: baseTime
            )
        )

        // When
        let count = try await lookup.resolvePendingScans()

        // Then
        #expect(count == 0)
        let scans = try inventory.repository.fetchUnresolvedScans()
        #expect(scans.count == 1)
        #expect(scans.first?.gtin == gtinA)
        #expect(try inventory.repository.fetchProduct(gtin: gtinA) == nil)
    }

    /// When a Product with the scanned GTIN already exists, it is
    /// reused (no duplicate) and the quantity is booked onto it.
    ///
    /// Given: an existing manual Product, a queued scan of two units
    /// of the same GTIN and a resolving source
    /// When: resolvePendingScans() runs
    /// Then: it returns 1, the existing Product is unchanged (same
    /// id, name and source) and its stock is 2
    @Test func existingProductIsReusedAndQuantityAddedToIt() async throws {
        // Given
        let (inventory, lookup) = try makeLookup(sources: [
            StubCatalogSource(
                name: "mcp",
                outcomes: [
                    .product(
                        stubProduct(gtin: gtinA, name: "Mehl überholt", brand: "Neu")
                    )
                ]
            )
        ])
        let cellar = try #require(try inventory.cellar())
        let existing = try inventory.repository.createProduct(
            Product(
                gtin: gtinA,
                name: "Mehl",
                brand: "Mühle",
                imageURL: nil,
                source: .manual
            )
        )
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinA,
                locationID: cellar.id,
                quantity: 2,
                createdAt: baseTime
            )
        )

        // When
        let count = try await lookup.resolvePendingScans()

        // Then
        #expect(count == 1)
        let product = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        #expect(product.id == existing.id)
        #expect(product.name == "Mehl")
        #expect(product.source == .manual)
        let stock = try #require(
            try inventory.repository.fetchStockLevel(
                productID: existing.id,
                locationID: cellar.id
            )
        )
        #expect(stock.quantity == 2)
        #expect(try inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// When the lookup throws mid-queue (e.g. the network is down),
    /// the run stops: earlier scans are fully booked and deleted,
    /// the remaining ones stay in the queue, and the error
    /// propagates.
    ///
    /// Given: two queued scans (A earlier, B later) and a source
    /// chain that resolves A and then throws for B
    /// When: resolvePendingScans() runs
    /// Then: it throws the source error, A is booked and out of the
    /// queue, B is still in the queue with no Product created
    @Test func lookupErrorStopsQueueAndKeepsRemainingScans() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [
            .product(stubProduct(gtin: gtinA, name: "Mehl")),
            .error(CatalogError.network(reason: "offline"))
        ])
        let (inventory, lookup) = try makeLookup(sources: [mcp])
        let cellar = try #require(try inventory.cellar())
        let pantry = try #require(try inventory.pantry())
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinA,
                locationID: cellar.id,
                quantity: 1,
                createdAt: baseTime
            )
        )
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinB,
                locationID: pantry.id,
                quantity: 2,
                createdAt: baseTime.addingTimeInterval(1)
            )
        )

        // When/Then: the error propagates
        await #expect(throws: CatalogError.network(reason: "offline")) {
            try await lookup.resolvePendingScans()
        }

        // The first scan is fully booked and out of the queue...
        let productA = try #require(try inventory.repository.fetchProduct(gtin: gtinA))
        let stockA = try #require(
            try inventory.repository.fetchStockLevel(
                productID: productA.id,
                locationID: cellar.id
            )
        )
        #expect(stockA.quantity == 1)
        // ...the second scan stays in the queue, unbooked.
        let scans = try inventory.repository.fetchUnresolvedScans()
        #expect(scans.count == 1)
        #expect(scans.first?.gtin == gtinB)
        #expect(try inventory.repository.fetchProduct(gtin: gtinB) == nil)
    }

    /// The queue continues past unresolvable scans: resolvable scans
    /// around an unresolvable one are still booked.
    ///
    /// Given: three queued scans A, B, C (B not resolvable)
    /// When: resolvePendingScans() runs
    /// Then: it returns 2, A and C are booked and only B remains in
    /// the queue
    @Test func queueContinuesPastUnresolvableScans() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [
            .product(stubProduct(gtin: gtinA, name: "Mehl")),
            .notFound,
            .product(stubProduct(gtin: gtinC, name: "Brot"))
        ])
        let (inventory, lookup) = try makeLookup(sources: [mcp])
        let cellar = try #require(try inventory.cellar())
        let pantry = try #require(try inventory.pantry())
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinA,
                locationID: cellar.id,
                quantity: 1,
                createdAt: baseTime
            )
        )
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinB,
                locationID: pantry.id,
                quantity: 1,
                createdAt: baseTime.addingTimeInterval(1)
            )
        )
        _ = try inventory.repository.recordUnresolvedScan(
            UnresolvedScan(
                gtin: gtinC,
                locationID: cellar.id,
                quantity: 2,
                createdAt: baseTime.addingTimeInterval(2)
            )
        )

        // When
        let count = try await lookup.resolvePendingScans()

        // Then
        #expect(count == 2)
        let scans = try inventory.repository.fetchUnresolvedScans()
        #expect(scans.count == 1)
        #expect(scans.first?.gtin == gtinB)
        let productC = try #require(try inventory.repository.fetchProduct(gtin: gtinC))
        let stockC = try #require(
            try inventory.repository.fetchStockLevel(
                productID: productC.id,
                locationID: cellar.id
            )
        )
        #expect(stockC.quantity == 2)
    }
}
