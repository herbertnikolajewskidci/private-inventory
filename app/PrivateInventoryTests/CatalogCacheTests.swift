import Foundation
import GRDB
@testable import PrivateInventory
import Testing

/// The catalog cache: GRDB round-trips for positive and negative
/// entries, the replace-on-same-GTIN rule and the expiry boundary
/// (ADR-0002, ticket #14).
struct CatalogCacheTests {
    private let gtin = "4000000000001"
    private let resolvedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCache() throws -> (TestInventory, GRDBCatalogCache) {
        let inventory = try TestInventory()
        return (inventory, GRDBCatalogCache(database: inventory.database))
    }

    /// A positive entry survives a store/fetch round-trip unchanged.
    ///
    /// Given: a fresh in-memory database
    /// When: a positive entry is stored and fetched by its GTIN
    /// Then: all fields are identical
    @Test func positiveEntryRoundTripsThroughGrdb() throws {
        // Given
        let (_, cache) = try makeCache()
        let entry = CatalogCacheEntry.positive(
            gtin: gtin,
            name: "Mehl",
            brand: "Mühle",
            imageURL: URL(string: "https://example.com/mehl.png"),
            source: .mcp,
            resolvedAt: resolvedAt,
            expiresAt: resolvedAt.addingTimeInterval(3600)
        )

        // When
        try cache.store(entry)
        let fetched = try cache.entry(gtin: gtin)

        // Then
        #expect(fetched == entry)
    }

    /// A negative entry (no product fields) survives the round-trip.
    ///
    /// Given: a fresh in-memory database
    /// When: a negative entry is stored and fetched by its GTIN
    /// Then: it comes back with nil product fields and isNegative set
    @Test func negativeEntryRoundTripsThroughGrdb() throws {
        // Given
        let (_, cache) = try makeCache()
        let entry = CatalogCacheEntry.negative(
            gtin: gtin,
            resolvedAt: resolvedAt,
            expiresAt: resolvedAt.addingTimeInterval(86400)
        )

        // When
        try cache.store(entry)
        let fetched = try #require(try cache.entry(gtin: gtin))

        // Then
        #expect(fetched == entry)
        #expect(fetched.isNegative)
        #expect(fetched.name == nil)
        #expect(fetched.brand == nil)
        #expect(fetched.imageURL == nil)
        #expect(fetched.source == nil)
    }

    /// A GTIN without a cached entry yields no entry.
    ///
    /// Given: a fresh in-memory database with one stored entry
    /// When: a different GTIN is requested
    /// Then: nil is returned
    @Test func unknownGtinYieldsNoEntry() throws {
        // Given
        let (_, cache) = try makeCache()
        try cache.store(
            CatalogCacheEntry.negative(
                gtin: gtin,
                resolvedAt: resolvedAt,
                expiresAt: resolvedAt.addingTimeInterval(86400)
            )
        )

        // When/Then
        #expect(try cache.entry(gtin: "9999999999999") == nil)
    }

    /// Storing a second entry for the same GTIN replaces the first
    /// one instead of creating a duplicate row.
    ///
    /// Given: a stored positive entry
    /// When: a negative entry for the same GTIN is stored
    /// Then: the fetch returns the new entry and the table holds
    /// exactly one row for the GTIN
    @Test func storingSameGtinReplacesExistingEntry() throws {
        // Given
        let (inventory, cache) = try makeCache()
        let positive = CatalogCacheEntry.positive(
            gtin: gtin,
            name: "Mehl",
            brand: "Mühle",
            imageURL: nil,
            source: .mcp,
            resolvedAt: resolvedAt,
            expiresAt: resolvedAt.addingTimeInterval(3600)
        )
        try cache.store(positive)

        // When
        let negative = CatalogCacheEntry.negative(
            gtin: gtin,
            resolvedAt: resolvedAt.addingTimeInterval(3600),
            expiresAt: resolvedAt.addingTimeInterval(3600 + 86400)
        )
        try cache.store(negative)

        // Then: the new data is under the original row identity, and
        // the table holds exactly one row for the GTIN.
        let fetched = try #require(try cache.entry(gtin: gtin))
        #expect(fetched.id == positive.id)
        #expect(fetched.isNegative)
        #expect(fetched.resolvedAt == negative.resolvedAt)
        #expect(fetched.expiresAt == negative.expiresAt)
        let rowCount = try inventory.queue.read { database in
            try CatalogCacheEntry
                .filter(Column("gtin") == gtin)
                .fetchCount(database)
        }
        #expect(rowCount == 1)
    }

    /// Replacing an entry keeps the row identity, so a later CloudKit
    /// sync (ADR-0005) sees an update, not a delete plus an insert.
    ///
    /// Given: a stored entry with a known row id
    /// When: a new entry (different id) for the same GTIN is stored
    /// Then: the fetched entry carries the original row id
    @Test func replacingEntryKeepsRowIdentity() throws {
        // Given
        let (_, cache) = try makeCache()
        let first = CatalogCacheEntry.positive(
            gtin: gtin,
            name: "Mehl",
            brand: "Mühle",
            imageURL: nil,
            source: .mcp,
            resolvedAt: resolvedAt,
            expiresAt: resolvedAt.addingTimeInterval(3600)
        )
        try cache.store(first)

        // When: a new entry with a different id, for the same GTIN
        let second = CatalogCacheEntry(
            id: UUID(),
            gtin: gtin,
            name: "Mehl (überholt)",
            brand: "Mühle",
            imageURL: nil,
            source: .search,
            resolvedAt: resolvedAt.addingTimeInterval(3600),
            expiresAt: resolvedAt.addingTimeInterval(7200),
            isNegative: false
        )
        try cache.store(second)

        // Then
        let fetched = try #require(try cache.entry(gtin: gtin))
        #expect(fetched.id == first.id)
        #expect(fetched.name == "Mehl (überholt)")
        #expect(fetched.source == .search)
    }

    /// The expiry boundary is inclusive: an entry whose `expiresAt`
    /// equals `now` is already expired (fresh means strictly
    /// `now < expiresAt`).
    ///
    /// Given: an entry expiring at time T
    /// When: isExpired(now:) is asked at T-1s, T and T+1s
    /// Then: false, true, true
    @Test func isExpiredTreatsEqualTimestampAsExpired() {
        // Given
        let entry = CatalogCacheEntry.negative(
            gtin: gtin,
            resolvedAt: resolvedAt,
            expiresAt: resolvedAt.addingTimeInterval(86400)
        )
        let expiresAt = entry.expiresAt

        // When/Then
        #expect(!entry.isExpired(now: expiresAt.addingTimeInterval(-1)))
        #expect(entry.isExpired(now: expiresAt))
        #expect(entry.isExpired(now: expiresAt.addingTimeInterval(1)))
    }
}
