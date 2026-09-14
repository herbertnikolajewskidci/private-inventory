import GRDB

/// The schema migrations for the inventory database (ADR-0003,
/// ADR-0005).
///
/// All primary keys are UUIDs stored as text so that later CloudKit
/// sync needs no data migration (ADR-0005). Column names match the
/// Swift property names of the domain types, so no custom column
/// mapping is needed.
enum InventoryMigrations {
    /// The migrator with all migrations in order.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Tables for the four entities of ADR-0003.
        migrator.registerMigration("0001_initial_schema") { database in
            try database.create(table: "product") { table in
                table.column("id", .text).notNull().primaryKey()
                // The GTIN is the domain key of a Product: unique.
                table.column("gtin", .text).notNull().unique()
                table.column("name", .text).notNull()
                table.column("brand", .text).notNull()
                table.column("imageURL", .text)
                table.column("source", .text).notNull()
            }

            try database.create(table: "location") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("name", .text).notNull()
            }

            try database.create(table: "stock_level") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("productID", .text).notNull()
                    .references("product", onDelete: .cascade)
                table.column("locationID", .text).notNull()
                    .references("location", onDelete: .cascade)
                // Invariant: a quantity is never negative.
                table.column("quantity", .integer).notNull().check(sql: "quantity >= 0")
                // One StockLevel per Product × Location pair.
                table.uniqueKey(["productID", "locationID"])
            }

            try database.create(table: "unresolved_scan") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("gtin", .text).notNull()
                table.column("locationID", .text).notNull()
                    .references("location", onDelete: .cascade)
                table.column("quantity", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }

        // Default locations (ADR-0003): Keller, Vorratsschrank.
        migrator.registerMigration("0002_seed_default_locations") { database in
            try Location(name: "Keller").insert(database)
            try Location(name: "Vorratsschrank").insert(database)
        }

        return migrator
    }
}
