import Foundation
@testable import PrivateInventory
import Testing

/// The fallback-chain half of the lookup orchestrator: resolution
/// order, the error contract and the cache-write rules of ADR-0002
/// (ticket #14).
///
/// All tests use stubbed `CatalogSource`s and a controllable clock:
/// no network, no real time.
struct CatalogLookupChainTests {
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
                        gtin: CatalogLookupHarness.gtin,
                        name: "Mehl",
                        source: .obf
                    )
                )
            ]
        )
        let harness = try CatalogLookupHarness(sources: [mcp, search, obf])

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product?.source == .obf)
        #expect(await mcp.calledGtins == [CatalogLookupHarness.gtin])
        #expect(await search.calledGtins == [CatalogLookupHarness.gtin])
        #expect(await obf.calledGtins == [CatalogLookupHarness.gtin])
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
            outcomes: [.product(stubProduct(gtin: CatalogLookupHarness.gtin, name: "Mehl"))]
        )
        let search = StubCatalogSource(name: "search", outcomes: [])
        let obf = StubCatalogSource(name: "obf", outcomes: [])
        let harness = try CatalogLookupHarness(sources: [mcp, search, obf])

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

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
            outcomes: [.error(CatalogError.invalidGtin(gtin: CatalogLookupHarness.gtin))]
        )
        let search = StubCatalogSource(
            name: "search",
            outcomes: [
                .product(
                    stubProduct(
                        gtin: CatalogLookupHarness.gtin,
                        name: "Mehl",
                        source: .search
                    )
                )
            ]
        )
        let harness = try CatalogLookupHarness(sources: [mcp, search])

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product?.source == .search)
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 1)
        let entry = try #require(try harness.cache.entry(gtin: CatalogLookupHarness.gtin))
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
        let harness = try CatalogLookupHarness(sources: [mcp, search])

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product == nil)
        #expect(try harness.cache.entry(gtin: CatalogLookupHarness.gtin) == nil)
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
        let harness = try CatalogLookupHarness(sources: [mcp, search])

        // When/Then
        await #expect(throws: CatalogError.network(reason: "offline")) {
            try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)
        }
        #expect(try harness.cache.entry(gtin: CatalogLookupHarness.gtin) == nil)
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
        let harness = try CatalogLookupHarness(sources: [mcp, search, obf])

        // When
        let product = try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)

        // Then
        #expect(product == nil)
        let entry = try #require(try harness.cache.entry(gtin: CatalogLookupHarness.gtin))
        #expect(entry.isNegative)
        #expect(
            entry.expiresAt.timeIntervalSince(entry.resolvedAt)
                == CatalogLookup.negativeTTL
        )
        #expect(await mcp.callCount == 1)
        #expect(await search.callCount == 1)
        #expect(await obf.callCount == 1)
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
        let harness = try CatalogLookupHarness(sources: [mcp])

        // When
        _ = try await harness.lookup.resolve(gtin: "111")
        _ = try await harness.lookup.resolve(gtin: "222")

        // Then
        let withHint = try #require(try harness.cache.entry(gtin: "111"))
        #expect(
            withHint.expiresAt.timeIntervalSince(withHint.resolvedAt)
                == dmSearchMaxAge
        )
        let withoutHint = try #require(try harness.cache.entry(gtin: "222"))
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
        let harness = try CatalogLookupHarness(sources: [])

        // When/Then
        await #expect(throws: CatalogError.network(reason: "no catalog sources configured")) {
            try await harness.lookup.resolve(gtin: CatalogLookupHarness.gtin)
        }
    }
}
