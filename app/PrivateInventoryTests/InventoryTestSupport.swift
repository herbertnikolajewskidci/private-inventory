import Foundation
import GRDB
@testable import PrivateInventory

/// Test support: a fresh in-memory inventory database per test, plus
/// sample values.
struct TestInventory {
    /// The GRDB connection of the in-memory database.
    let queue: DatabaseQueue
    /// The repository under test.
    let repository: GRDBInventoryRepository

    /// A fresh in-memory database with all migrations applied.
    init() throws {
        let database = try InventoryDatabase.makeInMemory()
        queue = database.queue
        repository = GRDBInventoryRepository(database: database)
    }

    /// A sample Product with a stable GTIN.
    static func product(gtin: String = "4000000000001", name: String = "Mehl") -> Product {
        Product(gtin: gtin, name: name, brand: "Mühle", imageURL: nil, source: .manual)
    }

    /// The seeded default location "Keller".
    func cellar() throws -> Location? {
        try repository.fetchLocations().first { $0.name == "Keller" }
    }

    /// The seeded default location "Vorratsschrank".
    func pantry() throws -> Location? {
        try repository.fetchLocations().first { $0.name == "Vorratsschrank" }
    }
}
