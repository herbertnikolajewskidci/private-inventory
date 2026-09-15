import Foundation
@testable import PrivateInventory
import Testing

/// The lookup orchestrator: cache-first resolution, fallback chain
/// order and the cache-write rules of ADR-0002 (ticket #14).
///
/// All tests use stubbed `CatalogSource`s and a controllable clock:
/// no network, no real time.
struct CatalogLookupTests {
    private static let gtin = "4000000000001"
    private static let startTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fresh in-memory cache plus a lookup with stub sources and a
    /// controllable clock.
    private func makeLookup(
        sources: [StubCatalogSource],
        clock: TestClock = TestClock(Self.startTime)
    ) throws -> (cache: GRDBCatalogCache, lookup: CatalogLookup, clock: TestClock) {
        let inventory = try TestInventory()
        let cache = GRDBCatalogCache(database: inventory.database)
        let lookup = CatalogLookup(
            cache: cache,
            sources: sources,
            repository: inventory.repository,
            now: { clock.current }
        )
        return (cache, lookup, clock)
    }

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
            outcomes: [.product(stubProduct(gtin: Self.gtin, name: "Mehl"))]
        )
        let (cache, lookup, clock) = try makeLookup(sources: [mcp])
        try cache.store(
            CatalogCacheEntry.positive(
                gtin: Self.gtin,
                name: "Mehl",
                brand: "Mühle",
                imageURL: nil,
                source: .mcp,
                resolvedAt: clock.current,
                expiresAt: clock.current.addingTimeInterval(3600)
            )
        )

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(
            product
                == ResolvedProduct(
                    gtin: Self.gtin,
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
                .product(stubProduct(gtin: Self.gtin, name: "Neues Mehl", brand: "Mühle"))
            ]
        )
        let (cache, lookup, clock) = try makeLookup(sources: [mcp])
        try cache.store(
            CatalogCacheEntry.positive(
                gtin: Self.gtin,
                name: "Altes Mehl",
                brand: "Alt",
                imageURL: nil,
                source: .mcp,
                resolvedAt: clock.current,
                expiresAt: clock.current.addingTimeInterval(3600)
            )
        )
        clock.advance(by: 2 * 3600)

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product?.name == "Neues Mehl")
        #expect(await mcp.callCount == 1)
        let entry = try #require(try cache.entry(gtin: Self.gtin))
        #expect(entry.name == "Neues Mehl")
        #expect(!entry.isExpired(now: clock.current))
        #expect(entry.resolvedAt == clock.current)
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
        let (cache, lookup, clock) = try makeLookup(sources: [mcp])
        try cache.store(
            CatalogCacheEntry.negative(
                gtin: Self.gtin,
                resolvedAt: clock.current,
                expiresAt: clock.current.addingTimeInterval(3600)
            )
        )

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

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
        let (cache, lookup, clock) = try makeLookup(sources: [mcp])
        try cache.store(
            CatalogCacheEntry.negative(
                gtin: Self.gtin,
                resolvedAt: clock.current,
                expiresAt: clock.current.addingTimeInterval(3600)
            )
        )
        clock.advance(by: 2 * 3600)

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product == nil)
        #expect(await mcp.callCount == 1)
        let entry = try #require(try cache.entry(gtin: Self.gtin))
        #expect(entry.isNegative)
        #expect(!entry.isExpired(now: clock.current))
        #expect(
            entry.expiresAt.timeIntervalSince(entry.resolvedAt)
                == CatalogLookup.negativeTTL
        )
    }

    /// The fallback chain runs in the configured order: MCP first,
    /// then dm search, then OBF/OFF.
    ///
    /// Given: MCP and search answer not-found, OBF/OFF resolves
    /// When: the GTIN is resolved
    /// Then: the product comes from OBF/OFF and every source was
    /// called exactly once, in that order
    @Test func fallbackChainRunsInMcpSearchObfOrder() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [.notFound])
        let search = StubCatalogSource(name: "search", outcomes: [.notFound])
        let obf = StubCatalogSource(
            name: "obf",
            outcomes: [
                .product(
                    stubProduct(
                        gtin: Self.gtin,
                        name: "Mehl",
                        source: .obf
                    )
                )
            ]
        )
        let (_, lookup, _) = try makeLookup(sources: [mcp, search, obf])

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product?.source == .obf)
        #expect(await mcp.calledGtins == [Self.gtin])
        #expect(await search.calledGtins == [Self.gtin])
        #expect(await obf.calledGtins == [Self.gtin])
    }

    /// A hit at the first source stops the chain: later sources are
    /// not called.
    ///
    /// Given: MCP resolves, search and OBF/OFF are configured
    /// When: the GTIN is resolved
    /// Then: the product comes from MCP and the later sources were
    /// not called
    @Test func firstHitStopsTheChain() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [.product(stubProduct(gtin: Self.gtin, name: "Mehl"))]
        )
        let search = StubCatalogSource(name: "search", outcomes: [])
        let obf = StubCatalogSource(name: "obf", outcomes: [])
        let (_, lookup, _) = try makeLookup(sources: [mcp, search, obf])

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product?.source == .mcp)
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 0)
        #expect(await obf.callCount == 0)
    }

    /// A thrown error (including invalidGtin) falls through to the
    /// next source; the failed source never yields a cache entry.
    ///
    /// Given: MCP throws invalidGtin, search resolves
    /// When: the GTIN is resolved
    /// Then: the product comes from search and the stored entry is
    /// the positive one from search — no negative was written on top
    /// of the error
    @Test func thrownErrorFallsThroughToNextSource() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [.error(CatalogError.invalidGtin(gtin: Self.gtin))]
        )
        let search = StubCatalogSource(
            name: "search",
            outcomes: [
                .product(
                    stubProduct(
                        gtin: Self.gtin,
                        name: "Mehl",
                        source: .search
                    )
                )
            ]
        )
        let (cache, lookup, _) = try makeLookup(sources: [mcp, search])

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product?.source == .search)
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 1)
        let entry = try #require(try cache.entry(gtin: Self.gtin))
        #expect(!entry.isNegative)
        #expect(entry.source == .search)
    }

    /// Error contract: when one source threw, no negative entry may
    /// be cached even if another source answered not-found — the
    /// truth is unknown while a source could not be consulted.
    ///
    /// Given: MCP throws network, search answers not-found
    /// When: the GTIN is resolved
    /// Then: nil is returned and no cache entry is written
    @Test func thrownErrorSuppressesNegativeCacheEntry() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [.error(CatalogError.network(reason: "offline"))]
        )
        let search = StubCatalogSource(name: "search", outcomes: [.notFound])
        let (cache, lookup, _) = try makeLookup(sources: [mcp, search])

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product == nil)
        #expect(try cache.entry(gtin: Self.gtin) == nil)
    }

    /// When every source throws, the last error is rethrown and
    /// nothing is cached.
    ///
    /// Given: MCP throws parse, search throws network
    /// When: the GTIN is resolved
    /// Then: the last error (network) is rethrown and no cache entry
    /// is written
    @Test func allSourcesThrowRethrowsLastErrorAndStoresNothing() async throws {
        // Given
        let mcp = StubCatalogSource(
            name: "mcp",
            outcomes: [.error(CatalogError.parse(reason: "malformed"))]
        )
        let search = StubCatalogSource(
            name: "search",
            outcomes: [.error(CatalogError.network(reason: "offline"))]
        )
        let (cache, lookup, _) = try makeLookup(sources: [mcp, search])

        // When/Then
        await #expect(throws: CatalogError.network(reason: "offline")) {
            try await lookup.resolve(gtin: Self.gtin)
        }
        #expect(try cache.entry(gtin: Self.gtin) == nil)
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 1)
    }

    /// When every source answers not-found, a negative entry is
    /// cached and nil is returned.
    ///
    /// Given: three sources, all not-found
    /// When: the GTIN is resolved
    /// Then: nil is returned, every source was called once and a
    /// negative entry with the negative TTL is stored
    @Test func allSourcesNotFoundStoresNegativeEntryAndReturnsNil() async throws {
        // Given
        let mcp = StubCatalogSource(name: "mcp", outcomes: [])
        let search = StubCatalogSource(name: "search", outcomes: [])
        let obf = StubCatalogSource(name: "obf", outcomes: [])
        let (cache, lookup, _) = try makeLookup(sources: [mcp, search, obf])

        // When
        let product = try await lookup.resolve(gtin: Self.gtin)

        // Then
        #expect(product == nil)
        let entry = try #require(try cache.entry(gtin: Self.gtin))
        #expect(entry.isNegative)
        #expect(
            entry.expiresAt.timeIntervalSince(entry.resolvedAt)
                == CatalogLookup.negativeTTL
        )
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 1)
        #expect(await obf.callCount == 1)
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
        let (cache, lookup, clock) = try makeLookup(sources: [mcp, search, obf])
        try cache.store(
            CatalogCacheEntry.negative(
                gtin: Self.gtin,
                resolvedAt: clock.current,
                expiresAt: clock.current.addingTimeInterval(CatalogLookup.negativeTTL)
            )
        )

        // When
        for _ in 0 ..< 5 {
            #expect(try await lookup.resolve(gtin: Self.gtin) == nil)
        }

        // Then
        #expect(await mcp.callCount == 0)
        #expect(await search.callCount == 0)
        #expect(await obf.callCount == 0)
    }

    /// The positive TTL prefers the source's cache-control hint and
    /// falls back to 30 days when the source gives no hint.
    ///
    /// Given: one source answering a 4-day hint for the first GTIN
    /// and no hint for the second
    /// When: both GTINs are resolved
    /// Then: the first entry expires after 4 days, the second after
    /// the 30-day fallback
    @Test func positiveTTLPrefersSourceHintOverFallback() async throws {
        // Given
        let dmSearchMaxAge: TimeInterval = 345_600 // 4 days
        let mcp = StubCatalogSource(name: "mcp", outcomes: [
            .product(stubProduct(gtin: "111", name: "Mit Hinweis", cacheTTL: dmSearchMaxAge)),
            .product(stubProduct(gtin: "222", name: "Ohne Hinweis"))
        ])
        let (cache, lookup, _) = try makeLookup(sources: [mcp])

        // When
        _ = try await lookup.resolve(gtin: "111")
        _ = try await lookup.resolve(gtin: "222")

        // Then
        let withHint = try #require(try cache.entry(gtin: "111"))
        #expect(
            withHint.expiresAt.timeIntervalSince(withHint.resolvedAt)
                == dmSearchMaxAge
        )
        let withoutHint = try #require(try cache.entry(gtin: "222"))
        #expect(
            withoutHint.expiresAt.timeIntervalSince(withoutHint.resolvedAt)
                == CatalogLookup.positiveTTLFallback
        )
    }

    /// A lookup without any configured source is a configuration
    /// error: it throws instead of silently caching a negative.
    ///
    /// Given: a lookup with an empty source chain
    /// When: a GTIN is resolved
    /// Then: a CatalogError.network explaining the misconfiguration
    /// is thrown
    @Test func resolveWithoutSourcesThrows() async throws {
        // Given
        let (_, lookup, _) = try makeLookup(sources: [])

        // When/Then
        await #expect(throws: CatalogError.network(reason: "no catalog sources configured")) {
            try await lookup.resolve(gtin: Self.gtin)
        }
    }
}
