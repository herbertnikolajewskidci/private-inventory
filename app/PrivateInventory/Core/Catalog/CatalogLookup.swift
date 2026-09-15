import Foundation

/// The catalog lookup orchestrator (ADR-0002, ticket #14).
///
/// Resolves a GTIN cache-first: a fresh cache entry short-circuits
/// the network entirely, everything else runs the fallback chain of
/// `CatalogSource`s (production order: dm MCP, dm search,
/// OBF/OFF). Also re-resolves the UnresolvedScan queue, so GTINs
/// that could not be resolved at scan time are booked as soon as a
/// source can answer for them (ADR-0003).
///
/// The orchestrator is transport-free (Foundation only, ADR-0007):
/// sources, cache and repository are injected, which is what keeps
/// it testable without a network.
struct CatalogLookup {
    /// Fallback TTL for positive entries of sources that give no
    /// `cache-control` hint (`cacheTTL == nil`).
    ///
    /// 30 days: long enough to spare the rate-limited APIs from
    /// re-lookups of the same GTIN (scanning the same product
    /// weekly must not hit the network again), short enough that a
    /// renamed or rebranded product does not stay stale for a
    /// season. Sources *with* a hint (e.g. dm search: 4 days) always
    /// win over this value.
    static let positiveTTLFallback: TimeInterval = 30 * 24 * 3600

    /// TTL for negative entries.
    ///
    /// 1 day: shorter than the positive TTL, so that a GTIN newly
    /// listed by a source appears within a day instead of staying
    /// cached as not-found for a month.
    static let negativeTTL: TimeInterval = 24 * 3600

    private let cache: any CatalogCache
    private let sources: [any CatalogSource]
    private let repository: InventoryRepository?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - cache: the catalog cache (positive and negative entries).
    ///   - sources: the fallback chain, in resolution order
    ///     (first source first).
    ///   - repository: the inventory repository, required only for
    ///     `resolvePendingScans()`; `nil` for pure lookups.
    ///   - now: the clock; injectable so tests can control expiry
    ///     deterministically. Defaults to the system time.
    init(
        cache: any CatalogCache,
        sources: [any CatalogSource],
        repository: InventoryRepository? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.sources = sources
        self.repository = repository
        self.now = now
    }

    // MARK: - GTIN resolution

    /// Resolves a GTIN to product data: fresh cache entry first,
    /// then the source chain.
    ///
    /// Behavior by cache state:
    /// - fresh positive entry → returned directly, with `cacheTTL`
    ///   set to `nil`: the TTL has already been applied when the
    ///   entry was stored (that is what `expiresAt` encodes), so no
    ///   further hint is needed or used.
    /// - fresh negative entry → `nil`, with zero source calls
    ///   (invariant: the negative cache suppresses re-lookups).
    /// - expired entry (either kind) → behaves like a miss; the
    ///   chain runs and the entry is refreshed.
    ///
    /// Behavior by chain outcome (on a miss):
    /// - a source resolves the GTIN → positive entry stored
    ///   (`expiresAt = resolvedAt + (cacheTTL ?? positiveTTLFallback)`),
    ///   product returned, later sources are not called.
    /// - every source answers cleanly with not-found → negative
    ///   entry stored (`expiresAt = resolvedAt + negativeTTL`),
    ///   `nil` returned.
    /// - a source throws (`CatalogError`, including
    ///   `invalidGtin`) → fall through to the next source; no cache
    ///   entry is written for the GTIN by this run (error contract:
    ///   a thrown error means the source is unusable, never a
    ///   not-found, so no negative may be cached on top of it).
    /// - every source threw → the last error is rethrown, nothing is
    ///   stored.
    ///
    /// - Parameter gtin: the barcode number as scanned (digits).
    /// - Returns: the resolved product, or `nil` for a clean
    ///   not-found.
    /// - Throws: the last `CatalogError` of the chain when every
    ///   source threw (or no source is configured).
    func resolve(gtin: String) async throws -> ResolvedProduct? {
        if let entry = try cache.entry(gtin: gtin), !entry.isExpired(now: now()) {
            if entry.isNegative {
                // Fresh negative: the chain already answered for
                // this GTIN; suppress the re-lookup entirely.
                return nil
            }
            if let name = entry.name, let brand = entry.brand,
               let source = entry.source
            {
                return ResolvedProduct(
                    gtin: gtin,
                    name: name,
                    brand: brand,
                    imageURL: entry.imageURL,
                    source: source,
                    cacheTTL: nil
                )
            }
            // Defensive: a positive entry must carry product data.
            // A corrupt entry is treated as a miss so the chain can
            // fix it.
        }

        // Cache miss or expired entry: run the source chain.
        let resolvedAt = now()
        var lastError: (any Error)?
        var gotCleanAnswer = false

        for source in sources {
            do {
                let product = try await source.resolve(gtin: gtin)
                if let product {
                    try cache.store(
                        CatalogCacheEntry.positive(
                            gtin: gtin,
                            name: product.name,
                            brand: product.brand,
                            imageURL: product.imageURL,
                            source: product.source,
                            resolvedAt: resolvedAt,
                            expiresAt: resolvedAt
                                + (product.cacheTTL ?? Self.positiveTTLFallback)
                        )
                    )
                    return product
                }
                // Clean not-found: this source has no data, try the
                // next one.
                gotCleanAnswer = true
            } catch {
                // Error contract: the source is unusable for this
                // request. Fall through; the last error is kept so
                // an all-failed chain can report why.
                lastError = error
            }
        }

        // No source resolved the GTIN.
        guard gotCleanAnswer else {
            // Every source threw (or none is configured): the
            // outcome is unknown, nothing may be cached; propagate
            // the last error.
            throw lastError
                ?? CatalogError.network(reason: "no catalog sources configured")
        }
        if lastError == nil {
            // Every source answered cleanly with not-found: cache
            // the negative so repeat scans do not re-hit the APIs.
            try cache.store(
                CatalogCacheEntry.negative(
                    gtin: gtin,
                    resolvedAt: resolvedAt,
                    expiresAt: resolvedAt + Self.negativeTTL
                )
            )
        }
        // Mixed outcome (some source threw, at least one answered
        // cleanly): return the clean answer but store no entry —
        // the error contract forbids caching while a source could
        // not be consulted.
        return nil
    }

    // MARK: - UnresolvedScan queue

    /// Re-resolves the UnresolvedScan queue (ADR-0003).
    ///
    /// For every queued scan, in `createdAt` order: run the
    /// cache-first lookup for the scanned GTIN.
    /// - resolved → the `Product` is created when missing (an
    ///   existing Product with the same GTIN is reused), the stock
    ///   is booked with one `scanIn` per scanned unit at the scan's
    ///   location, and the scan is removed from the queue.
    /// - still unresolvable (clean not-found) → the scan stays in
    ///   the queue, the next scan is processed.
    /// - lookup throws (e.g. the network is down) → stop
    ///   immediately; scans processed before it are already booked
    ///   and deleted, the remaining ones stay in the queue, and the
    ///   error propagates.
    ///
    /// - Returns: the number of scans resolved in this run
    ///   (`0` when no repository is configured).
    func resolvePendingScans() async throws -> Int {
        guard let repository else { return 0 }

        var resolved = 0
        for scan in try repository.fetchUnresolvedScans() {
            guard let catalog = try await resolve(gtin: scan.gtin) else {
                // Still unresolvable: leave the scan in the queue
                // and try the next one.
                continue
            }

            // The product may already exist (added manually or by an
            // earlier run): reuse it instead of creating a
            // duplicate.
            let product: Product
            do {
                product = try repository.createProduct(
                    Product(
                        gtin: catalog.gtin,
                        name: catalog.name,
                        brand: catalog.brand,
                        imageURL: catalog.imageURL,
                        source: catalog.source
                    )
                )
            } catch InventoryError.duplicateGTIN {
                guard let existing = try repository.fetchProduct(gtin: catalog.gtin) else {
                    // Defensive: the product vanished between the
                    // failed create and the fetch; report the
                    // conflict again.
                    throw InventoryError.duplicateGTIN
                }
                product = existing
            }

            // Einbuchen: one scanIn per scanned unit
            // (Supermarkt-Kassen-Prinzip, CONTEXT.md).
            for _ in 0 ..< scan.quantity {
                _ = try repository.scanIn(productID: product.id, locationID: scan.locationID)
            }
            try repository.deleteUnresolvedScan(id: scan.id)
            resolved += 1
        }
        return resolved
    }
}
