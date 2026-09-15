import Foundation
import GRDB
@testable import PrivateInventory
import Testing

/// The schema migrations: tables, default locations, idempotency
/// across app starts, and the GTIN unique constraint.
struct InventoryMigrationsTests {
    /// All four tables exist after the migrations ran.
    ///
    /// Given: a fresh in-memory database
    /// When: the migrations run (InventoryDatabase creation)
    /// Then: the product, location, stock_level and unresolved_scan
    /// tables exist
    @Test func migrationsCreateAllFourTables() throws {
        // Given/When: fresh database, migrations applied
        let database = try InventoryDatabase.makeInMemory()

        // Then: the four tables exist
        try database.queue.read { database in
            let tableNames = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            #expect(tableNames.contains("product"))
            #expect(tableNames.contains("location"))
            #expect(tableNames.contains("stock_level"))
            #expect(tableNames.contains("unresolved_scan"))
        }
    }

    /// The default locations Keller and Vorratsschrank exist after
    /// the migrations ran.
    ///
    /// Given: a fresh in-memory database
    /// When: the migrations run
    /// Then: both default locations can be read by name
    @Test func migrationsSeedDefaultLocations() throws {
        // Given/When: fresh database, migrations applied
        let inventory = try TestInventory()
        let names = try inventory.repository.fetchLocations().map(\.name)

        // Then: both defaults exist
        #expect(names.contains("Keller"))
        #expect(names.contains("Vorratsschrank"))
    }

    /// The migrations are idempotent across app starts: re-opening
    /// the same database file and running the migrations again does
    /// not fail and keeps the data.
    ///
    /// Given: a database file that has been migrated once, with one
    /// product stored
    /// When: the "app starts" again (open file, run migrations)
    /// Then: the product is still there
    @Test func migrationsAreIdempotentAcrossAppStarts() throws {
        // Given: a file-based database, migrated and used once
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-inventory-tests")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            // First "app start": migrate, store a product, close
            let firstStart = try InventoryDatabase(path: fileURL.path)
            let repository = GRDBInventoryRepository(database: firstStart)
            _ = try repository.createProduct(TestInventory.product())
        }

        // When: second "app start" on the same file (re-migrates)
        let secondStart = try InventoryDatabase(path: fileURL.path)
        let repository = GRDBInventoryRepository(database: secondStart)

        // Then: the data from the first start is intact
        let product = try #require(try repository.fetchProduct(gtin: "4000000000001"))
        #expect(product.name == "Mehl")
    }

    /// The GTIN unique constraint is enforced by the database itself,
    /// independent of the repository.
    ///
    /// Given: a database with one product for a GTIN
    /// When: a second row with the same GTIN is inserted directly
    /// (raw SQL)
    /// Then: the database rejects the insert
    @Test func gtinUniqueConstraintIsEnforcedByDatabase() throws {
        // Given: one product with GTIN 4000000000001
        let inventory = try TestInventory()
        _ = try inventory.repository.createProduct(TestInventory.product())

        // When/Then: a direct SQL insert with the same GTIN is
        // rejected by the unique constraint
        let duplicateInsert = """
        INSERT INTO product (id, gtin, name, brand, source) \
        VALUES ('other-id', '4000000000001', 'Duplicate', 'Brand', 'manual')
        """
        #expect(throws: DatabaseError.self) {
            _ = try inventory.queue.write { database in
                try database.execute(sql: duplicateInsert)
            }
        }
    }

    /// The 0004 rebuild of unresolved_scan carries valid rows over
    /// unchanged (CodeRabbit finding, ticket #14: the CHECK
    /// constraint is added by rebuilding the table).
    ///
    /// Given: a database migrated up to 0003 that holds one
    /// unresolved scan
    /// When: the remaining migrations run ("app update")
    /// Then: the scan is still there with all its fields
    @Test func quantityCheckMigrationCarriesValidScansOver() throws {
        // Given: a file database migrated up to 0003 with one scan
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-inventory-tests")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let queue = try DatabaseQueue(path: fileURL.path)
        try InventoryMigrations.migrator.migrate(queue, upTo: "0003_catalog_cache")
        let cellarID = try queue.write { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM location WHERE name = 'Keller'"
            )
        }
        let scanID = UUID().uuidString
        try queue.write { database in
            try database.execute(
                sql: """
                INSERT INTO unresolved_scan (id, gtin, locationID, quantity, createdAt)
                VALUES (?, '0000000000000', ?, 2, ?)
                """,
                arguments: [scanID, cellarID, Date(timeIntervalSince1970: 1_700_000_000)]
            )
        }

        // When: the "app update" runs the remaining migrations
        try InventoryMigrations.migrator.migrate(queue)

        // Then: the scan survived the rebuild with all fields intact
        let restored = try queue.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT * FROM unresolved_scan WHERE id = ?",
                arguments: [scanID]
            )
        }
        let row = try #require(restored)
        #expect(row["gtin"] as String == "0000000000000")
        #expect(row["quantity"] as Int == 2)
        #expect(
            (row["createdAt"] as Date) == Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// The 0004 rebuild discards invalid legacy rows instead of
    /// failing: a pre-0004 database can hold negative quantities
    /// (nothing validated them before), and copying them into the
    /// constrained table would abort the migration and block the
    /// database from opening (CodeRabbit finding, ticket #14).
    ///
    /// Given: a database migrated up to 0003 that holds one valid
    /// and one negative-quantity unresolved scan
    /// When: the remaining migrations run ("app update")
    /// Then: the migration succeeds, the valid scan is carried over,
    /// the negative one is discarded
    @Test func quantityCheckMigrationDiscardsInvalidLegacyRows() throws {
        // Given: a file database migrated up to 0003 with one valid
        // and one negative-quantity scan
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-inventory-tests")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let queue = try DatabaseQueue(path: fileURL.path)
        try InventoryMigrations.migrator.migrate(queue, upTo: "0003_catalog_cache")
        let cellarID = try queue.write { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM location WHERE name = 'Keller'"
            )
        }
        try queue.write { database in
            try database.execute(
                sql: """
                INSERT INTO unresolved_scan (id, gtin, locationID, quantity, createdAt)
                VALUES (?, '0000000000000', ?, 2, ?),
                       (?, '0000000000000', ?, -1, ?)
                """,
                arguments: [
                    UUID().uuidString, cellarID, Date(timeIntervalSince1970: 1_700_000_000),
                    UUID().uuidString, cellarID, Date(timeIntervalSince1970: 1_700_000_001)
                ]
            )
        }

        // When: the "app update" runs the remaining migrations (this
        // must not fail on the negative legacy row)
        try InventoryMigrations.migrator.migrate(queue)

        // Then: the valid scan survived, the negative one is gone
        let scans = try queue.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM unresolved_scan")
        }
        #expect(scans.count == 1)
        let row = try #require(scans.first)
        #expect(row["gtin"] as String == "0000000000000")
        #expect(row["quantity"] as Int == 2)
    }
}
