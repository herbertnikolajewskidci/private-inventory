import Foundation
import GRDB

/// The GRDB implementation of `CatalogCache` (ADR-0002, ADR-0005:
/// persistence behind a repository protocol).
///
/// The cache holds at most one entry per GTIN, positive or negative
/// (unique constraint on `gtin`, migration 0003). Re-storing an entry
/// for an already known GTIN replaces the existing row and keeps its
/// row identity (`id`), so a later CloudKit sync sees an update, not
/// a delete plus an insert.
struct GRDBCatalogCache: CatalogCache {
    private let queue: DatabaseQueue

    init(database: InventoryDatabase) {
        queue = database.queue
    }

    func entry(gtin: String) throws -> CatalogCacheEntry? {
        try queue.read { database in
            try CatalogCacheEntry.filter(Column("gtin") == gtin).fetchOne(database)
        }
    }

    func store(_ entry: CatalogCacheEntry) throws {
        try queue.write { database in
            // Fetch + replace, the plain style of the repository
            // layer. The row identity is kept on replacement.
            let existing = try CatalogCacheEntry
                .filter(Column("gtin") == entry.gtin)
                .fetchOne(database)
            if let existing {
                // Replace the row, keeping its identity (the row's
                // id is a `let`, so rebuild the entry with it).
                let replaced = CatalogCacheEntry(
                    id: existing.id,
                    gtin: entry.gtin,
                    name: entry.name,
                    brand: entry.brand,
                    imageURL: entry.imageURL,
                    source: entry.source,
                    resolvedAt: entry.resolvedAt,
                    expiresAt: entry.expiresAt,
                    isNegative: entry.isNegative
                )
                try replaced.update(database)
            } else {
                try entry.insert(database)
            }
        }
    }
}
