import Foundation
@testable import PrivateInventory
import Testing

/// The cache-first half of the lookup orchestrator: fresh entries
/// short-circuit the chain, expired entries behave like misses, the
/// negative cache suppresses re-lookups (ADR-0002, ticket #14).
///
/// All tests use stubbed `CatalogSource`s and a controllable clock:
/// no network, no real time.
struct CatalogLookupCacheTests {
    /// A fresh positive cache entry short-circuits the chain.
    ///
    /// Given: a fresh positive entry and a configured source
    /// When: the GTIN is resolved
    /// Then: the cached product is returned (with cacheTTL nil — the
    /// TTL is already applied via expiresAt) and the source is not
    /// called
    @Test func freshPositiveEntryReturnsCachedProductWithoutSourceCalls() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [.product(stubProduct(gtin: CatalogLookupHarness.gtin, name: "Mehl"))]
        )
        let harness = try CatalogLookupHarness(sources: [mcp])
        try harness.cache.store(
            CatalogCacheEntry(
                gtin: CatalogLookupHarness.gtin,
                name: "Mehl",
                brand: "Mühle",
                imageURL: nil,
                source: .mcp,
                resolvedAt: harness.clock.current,
                expiresAt: harness.clock.current.addingTimeInterval(3600),
                isNegative: false
            )
        )

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(
            product
                == ResolvedProduct(
                    gtin: CatalogLookupHarness.gtin,
                    name: "Mehl",
                    brand: "Mühle",
                    imageURL: nil,
                    source: .mcp,
                    cacheTTL: nil
                )
        )
        #expect(await mcp.callCount == 0)
    }

    /// An expired positive entry behaves like a miss: the chain runs
    /// and the entry is refreshed with the new data and expiry.
    ///
    /// Given: a positive entry that expires in one hour, then two
    /// hours of clock time pass
    /// When: the GTIN is resolved
    /// Then: the chain runs once, the product comes from the source
    /// and the cache entry is fresh again
    @Test func expiredPositiveEntryRunsChainAndRefreshesCache() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [
                .product(stubProduct(
                    gtin: CatalogLookupHarness.gtin,
                    name: "Neues Mehl",
                    brand: "Mühle"
                ))
            ]
        )
        let harness = try CatalogLookupHarness(sources: [mcp])
        try harness.cache.store(
            CatalogCacheEntry(
                gtin: CatalogLookupHarness.gtin,
                name: "Altes Mehl",
                brand: "Alt",
                imageURL: nil,
                source: .mcp,
                resolvedAt: harness.clock.current,
                expiresAt: harness.clock.current.addingTimeInterval(3600),
                isNegative: false
            )
        )
        harness.clock.advance(by: 2 * 3600)

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product?.name == "Neues Mehl")
        #expect(await mcp.callCount == 1)
        let entry = try #require(try harness.cache.entry(gtin: CatalogLookupHarness.gtin))
        #expect(entry.name == "Neues Mehl")
        #expect(!entry.isExpired(now: harness.clock.current))
        #expect(entry.resolvedAt == harness.clock.current)
        // No cache-control hint from the stub: the fallback TTL
        // applies.
        #expect(
            entry.expiresAt.timeIntervalSince(entry.resolvedAt)
                == CatalogLookup.positiveTTLFallback
        )
    }

    /// A fresh negative entry suppresses the chain entirely.
    ///
    /// Given: a fresh negative entry and a configured source
    /// When: the GTIN is resolved
    /// Then: nil is returned and the source is not called
    @Test func freshNegativeEntryReturnsNilWithoutSourceCalls() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [])
        let harness = try CatalogLookupHarness(sources: [mcp])
        try harness.cache.store(
            CatalogCacheEntry.negative(
                gtin: CatalogLookupHarness.gtin,
                resolvedAt: harness.clock.current,
                expiresAt: harness.clock.current.addingTimeInterval(3600)
            )
        )

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product == nil)
        #expect(await mcp.callCount == 0)
    }

    /// An expired negative entry behaves like a miss: the chain runs
    /// again and the negative entry is refreshed.
    ///
    /// Given: a negative entry that expires in one hour, then two
    /// hours of clock time pass
    /// When: the GTIN is resolved
    /// Then: nil is returned, the chain ran once and the negative
    /// entry is fresh again
    @Test func expiredNegativeEntryRunsChainAgain() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [])
        let harness = try CatalogLookupHarness(sources: [mcp])
        try harness.cache.store(
            CatalogCacheEntry.negative(
                gtin: CatalogLookupHarness.gtin,
                resolvedAt: harness.clock.current,
                expiresAt: harness.clock.current.addingTimeInterval(3600)
            )
        )
        harness.clock.advance(by: 2 * 3600)

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product == nil)
        #expect(await mcp.callCount == 1)
        let entry = try #require(try harness.cache.entry(gtin: CatalogLookupHarness.gtin))
        #expect(entry.isNegative)
        #expect(!entry.isExpired(now: harness.clock.current))
        #expect(
            entry.expiresAt.timeIntervalSince(entry.resolvedAt)
                == CatalogLookup.negativeTTL
        )
    }

    /// Invariant (ADR-0006): while a negative entry is fresh,
    /// repeated lookups never reach the sources.
    ///
    /// Given: a fresh negative entry in the cache
    /// When: the GTIN is resolved five times in a row
    /// Then: every call returns nil and the source call count stays
    /// 0
    @Test func repeatedResolveOnFreshNegativeCacheKeepsSourceCallsAtZero() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [])
        let search = StubCatalogSource(name: "search", outcomes: [])
        let obf = StubCatalogSource(name: "obf", outcomes: [])
        let harness = try CatalogLookupHarness(sources: [mcp, search, obf])
        try harness.cache.store(
            CatalogCacheEntry.negative(
                gtin: CatalogLookupHarness.gtin,
                resolvedAt: harness.clock.current,
                expiresAt: harness.clock.current
                    .addingTimeInterval(CatalogLookup.negativeTTL)
            )
        )

        // When
        for _ in 0 ..< 5 {
            #expect(try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin) == nil)
        }

        // Then
        #expect(await mcp.callCount == 0)
        #expect(await search.callCount == 0)
        #expect(await obf.callCount == 0)
    }
}
