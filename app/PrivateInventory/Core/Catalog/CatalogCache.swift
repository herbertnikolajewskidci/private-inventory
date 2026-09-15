import Foundation

/// A cached catalog lookup result.
///
/// Either a positive entry (product data from a catalog source) or a
/// negative entry (the knowledge that no source has data for a GTIN,
/// ADR-0002). Negative entries carry no product fields: they are
/// stored with `name`, `brand`, `imageURL` and `source` all `nil` and
/// `isNegative` set.
struct CatalogCacheEntry: Equatable, Codable, Sendable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    /// The GTIN this entry was resolved for; the cache key.
    let gtin: String
    /// The product name; `nil` for negative entries.
    var name: String?
    /// The product brand; `nil` for negative entries.
    var brand: String?
    /// The product image URL; `nil` for negative entries.
    var imageURL: URL?
    /// The source the data came from; `nil` for negative entries.
    var source: ProductSource?
    /// When the entry was resolved.
    let resolvedAt: Date
    /// When the entry expires and must be re-resolved.
    var expiresAt: Date
    /// Whether this entry is a cached not-found.
    var isNegative: Bool

    init(
        id: UUID = UUID(),
        gtin: String,
        name: String?,
        brand: String?,
        imageURL: URL?,
        source: ProductSource?,
        resolvedAt: Date,
        expiresAt: Date,
        isNegative: Bool
    ) {
        self.id = id
        self.gtin = gtin
        self.name = name
        self.brand = brand
        self.imageURL = imageURL
        self.source = source
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
        self.isNegative = isNegative
    }

    /// A positive entry: product data from a catalog source.
    static func positive(
        gtin: String,
        name: String,
        brand: String,
        imageURL: URL?,
        source: ProductSource,
        resolvedAt: Date,
        expiresAt: Date
    ) -> CatalogCacheEntry {
        CatalogCacheEntry(
            gtin: gtin,
            name: name,
            brand: brand,
            imageURL: imageURL,
            source: source,
            resolvedAt: resolvedAt,
            expiresAt: expiresAt,
            isNegative: false
        )
    }

    /// A negative entry: no source has data for this GTIN.
    ///
    /// Caching the not-found is what suppresses re-lookups of
    /// unresolvable GTINs against rate-limited APIs (ADR-0002).
    static func negative(
        gtin: String,
        resolvedAt: Date,
        expiresAt: Date
    ) -> CatalogCacheEntry {
        CatalogCacheEntry(
            gtin: gtin,
            name: nil,
            brand: nil,
            imageURL: nil,
            source: nil,
            resolvedAt: resolvedAt,
            expiresAt: expiresAt,
            isNegative: true
        )
    }

    /// Whether the entry has expired as of `now`.
    ///
    /// Pure: the caller decides the current time, so tests can
    /// control expiry deterministically. The boundary is inclusive:
    /// an entry whose `expiresAt` equals `now` is already expired
    /// (fresh means strictly `now < expiresAt`).
    func isExpired(now: Date) -> Bool {
        now >= expiresAt
    }
}

/// Read/write access to the catalog cache.
///
/// Layer boundary (ADR-0007): the lookup orchestrator depends on
/// this protocol and never on GRDB. The GRDB implementation lives in
/// `Persistence/`.
protocol CatalogCache: Sendable {
    /// The cached entry for `gtin`, if any.
    ///
    /// Returns the entry regardless of expiry: whether an entry is
    /// still fresh is decided by the caller via `isExpired(now:)`.
    func entry(gtin: String) throws -> CatalogCacheEntry?

    /// Stores `entry`, inserting it or replacing the existing entry
    /// for the same GTIN (the cache holds at most one entry per
    /// GTIN).
    func store(_ entry: CatalogCacheEntry) throws
}
