import GRDB

/// GRDB persistence mapping for the domain types.
///
/// The conformances live in `Persistence/` (not `Core/`) so that the
/// domain types stay free of GRDB imports (ADR-0007 layer rule).
///
/// Table names are snake_case; column names match the Swift property
/// names (GRDB matches them case-insensitively), so no custom column
/// mapping is needed.
extension Product: FetchableRecord, PersistableRecord {
    static let databaseTableName = "product"

    /// UUIDs are stored as text (ADR-0005); the GRDB default is a
    /// 16-byte blob.
    static func databaseUUIDEncodingStrategy(for _: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

extension Location: FetchableRecord, PersistableRecord {
    static let databaseTableName = "location"

    /// UUIDs are stored as text (ADR-0005); the GRDB default is a
    /// 16-byte blob.
    static func databaseUUIDEncodingStrategy(for _: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

extension StockLevel: FetchableRecord, PersistableRecord {
    static let databaseTableName = "stock_level"

    /// UUIDs are stored as text (ADR-0005); the GRDB default is a
    /// 16-byte blob.
    static func databaseUUIDEncodingStrategy(for _: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

extension UnresolvedScan: FetchableRecord, PersistableRecord {
    static let databaseTableName = "unresolved_scan"

    /// UUIDs are stored as text (ADR-0005); the GRDB default is a
    /// 16-byte blob.
    static func databaseUUIDEncodingStrategy(for _: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

extension CatalogCacheEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "catalog_entry"

    /// UUIDs are stored as text (ADR-0005); the GRDB default is a
    /// 16-byte blob.
    static func databaseUUIDEncodingStrategy(for _: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}
