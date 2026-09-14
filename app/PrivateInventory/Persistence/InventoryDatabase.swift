import GRDB

/// The GRDB database for inventory data.
///
/// Runs all schema migrations on creation; creating the database for
/// an already migrated file (app start) applies nothing and is a
/// no-op for the data.
struct InventoryDatabase {
    /// The GRDB connection; thread-safe and serializes access.
    let queue: DatabaseQueue

    /// Opens (or creates) the database file at `path` and runs all
    /// pending migrations.
    init(path: String) throws {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        try Self.runMigrations(queue)
        self.queue = queue
    }

    /// An in-memory database with all migrations applied (tests).
    static func makeInMemory() throws -> InventoryDatabase {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        try Self.runMigrations(queue)
        return InventoryDatabase(queue: queue)
    }

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// Foreign keys are enforced in test builds and disabled in
    /// production builds, because CloudKit delivers records in
    /// arbitrary order (ADR-0005).
    private static var configuration: Configuration {
        var configuration = Configuration()
        #if DEBUG
            configuration.foreignKeysEnabled = true
        #else
            configuration.foreignKeysEnabled = false
        #endif
        return configuration
    }

    private static func runMigrations(_ queue: DatabaseQueue) throws {
        try InventoryMigrations.migrator.migrate(queue)
    }
}
