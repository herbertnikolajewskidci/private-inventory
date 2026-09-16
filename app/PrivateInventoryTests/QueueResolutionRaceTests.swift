import Foundation
@testable import PrivateInventory
import Testing

/// Queue re-resolution race tolerance (ticket #24, CodeRabbit
/// re-review): a row that a concurrent resolver already booked and
/// removed is tolerated — in its own file to keep
/// `QueueResolutionTests` within the file/type length limits.
struct QueueResolutionRaceTests {
    private let gtinA = "4000000000001"
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
    /// A row that a CONCURRENT resolver booked and removed between
    /// this run's fetch and its booking is tolerated (CodeRabbit):
    /// the run does not throw `missingParent`, it skips the row and
    /// keeps the remaining ones.
    ///
    /// Given: a local product under A and one queued row of A, in a
    /// repository whose booking reports the row as already resolved
    /// (the racing row was removed by the concurrent resolver)
    /// When: resolvePendingScans() runs
    /// Then: no error, the run returns 0 and simply skips the row
    @Test func concurrentResolverRemovesRowBeforeBookingIsTolerated() async throws {
        // Given
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let local = Product(
            gtin: gtinA,
            name: "Mehl",
            brand: "Mühle",
            imageURL: nil,
            source: .manual
        )
        let row = try UnresolvedScan(
            gtin: gtinA,
            locationID: cellar.id,
            quantity: 1,
            createdAt: baseTime
        )
        let lookup = CatalogLookup(
            cache: GRDBCatalogCache(database: inventory.database),
            sources: [],
            repository: RacingRepository(product: local, scans: [row]),
            now: { baseTime }
        )

        // When
        let count = try await lookup.resolvePendingScans()

        // Then: no throw, the racing row is skipped
        #expect(count == 0)
    }
}

/// A repository double whose booking always reports the row as
/// vanished (`missingParent`): a concurrent resolver (manual bind,
/// another queue run) booked and removed the row between this
/// run's queue fetch and its booking (CodeRabbit).
private final class RacingRepository: InventoryRepository, @unchecked Sendable {
    let product: Product
    let scans: [UnresolvedScan]

    init(product: Product, scans: [UnresolvedScan]) {
        self.product = product
        self.scans = scans
    }

    func fetchProduct(gtin _: String) throws -> Product? {
        product
    }

    func fetchUnresolvedScans() throws -> [UnresolvedScan] {
        scans
    }

    func bookUnresolvedScan(scanID _: UUID, productID _: UUID) throws -> StockLevel {
        throw InventoryError.missingParent
    }

    func fetchLocations() throws -> [Location] {
        fatalError("unused in this test")
    }

    func createProduct(_: Product) throws -> Product {
        fatalError("unused in this test")
    }

    func scanIn(productID _: UUID, locationID _: UUID) throws -> StockLevel {
        fatalError("unused in this test")
    }

    func withdraw(productID _: UUID, locationID _: UUID, amount _: Int) throws -> StockLevel {
        fatalError("unused in this test")
    }

    func transfer(
        productID _: UUID,
        fromLocationID _: UUID,
        toLocationID _: UUID,
        amount _: Int
    ) throws -> (source: StockLevel, destination: StockLevel) {
        fatalError("unused in this test")
    }

    func fetchStockLevels(productID _: UUID?) throws -> [StockLevel] {
        fatalError("unused in this test")
    }

    func fetchStockLevel(productID _: UUID, locationID _: UUID) throws -> StockLevel? {
        fatalError("unused in this test")
    }

    func recordUnresolvedScan(_: UnresolvedScan) throws -> UnresolvedScan {
        fatalError("unused in this test")
    }

    func deleteUnresolvedScan(id _: UUID) throws {
        fatalError("unused in this test")
    }

    func createGTINAlias(gtin _: String, productID _: UUID) throws {
        fatalError("unused in this test")
    }

    func bindGTIN(
        scannedGTIN _: String,
        product _: Product
    ) throws -> (product: Product, bookedRows: Int) {
        fatalError("unused in this test")
    }
}
