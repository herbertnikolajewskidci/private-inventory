import Foundation

/// The outcome of one scan in the scan session (Grilling #17).
enum ScanOutcome: Equatable {
    /// The GTIN resolved to a Product: booked +1 at the session
    /// location.
    case booked(product: Product, stockLevel: StockLevel)
    /// The GTIN could not be resolved (yet): counts as stock
    /// immediately; the background queue run books it later (ADR-0003).
    case queued(unresolvedScan: UnresolvedScan)
}

/// The always-on scan session (Grilling #17): the booking entry
/// point of the scan flow. No start/end, no per-scan location
/// dialog — every scan books silently at the session location
/// (ADR-0003, ADR-0008).
///
/// Framework-free (ADR-0007): depends only on the
/// `InventoryRepository` and `CatalogLookup` seams. Three booking
/// paths per scan, never waiting on the network: a local product
/// beats the cache, a cache hit books directly, everything else
/// queues the scan as `UnresolvedScan` and kicks the background
/// queue run (Trigger ①).
struct ScanSession {
    /// The Location every scan books at (never per-scan).
    let sessionLocationID: UUID

    private let repository: any InventoryRepository
    private let lookup: CatalogLookup
    /// Kicks the background queue re-resolution (Trigger ①):
    /// called synchronously right after a scan was queued. The
    /// default spawns the `resolvePendingScans()` task; tests inject
    /// a recording double for determinism.
    private let spawnQueueRun: @Sendable () -> Void
    private let now: @Sendable () -> Date

    init(
        sessionLocationID: UUID,
        repository: any InventoryRepository,
        lookup: CatalogLookup,
        spawnQueueRun: (@Sendable () -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionLocationID = sessionLocationID
        self.repository = repository
        self.lookup = lookup
        self.spawnQueueRun = spawnQueueRun ?? {
            Task { try? await lookup.resolvePendingScans() }
        }
        self.now = now
    }

    /// One scan: books +1 at the session location (supermarket
    /// checkout principle). Never throws for an unresolvable GTIN —
    /// that is the queued outcome, not a failure.
    func scan(gtin: String) async throws -> ScanOutcome {
        // Path 1: a local product (e.g. created manually) is the
        // user's curated truth and beats the external cache; this
        // also books offline.
        if let product = try repository.fetchProduct(gtin: gtin) {
            let level = try repository.scanIn(
                productID: product.id,
                locationID: sessionLocationID
            )
            return .booked(product: product, stockLevel: level)
        }

        // Path 2/3: cache-first lookup. A clean miss (nil) and a
        // thrown error (network down) both queue the scan: the scan
        // flow never breaks (ADR-0003).
        let resolved: ResolvedProduct?
        do {
            resolved = try await lookup.resolve(gtin: gtin)
        } catch {
            resolved = nil
        }

        if let catalog = resolved {
            let product = try Self.ensureProduct(
                resolved: catalog,
                repository: repository
            )
            let level = try repository.scanIn(
                productID: product.id,
                locationID: sessionLocationID
            )
            return .booked(product: product, stockLevel: level)
        }

        // Path 3: book immediately — one queue row per scan
        // (quantity 1; repeated scans stay separate rows), then
        // kick Trigger ①.
        let scan = try UnresolvedScan(
            gtin: gtin,
            locationID: sessionLocationID,
            quantity: 1,
            createdAt: now()
        )
        let recorded = try repository.recordUnresolvedScan(scan)
        spawnQueueRun()
        return .queued(unresolvedScan: recorded)
    }

    /// create-or-reuse for resolved catalog data — the same pattern
    /// as `CatalogLookup.resolvePendingScans` (ticket #14): create
    /// the Product; on `duplicateGTIN` reuse the existing one.
    private static func ensureProduct(
        resolved: ResolvedProduct,
        repository: any InventoryRepository
    ) throws -> Product {
        do {
            return try repository.createProduct(
                Product(
                    gtin: resolved.gtin,
                    name: resolved.name,
                    brand: resolved.brand,
                    imageURL: resolved.imageURL,
                    source: resolved.source
                )
            )
        } catch InventoryError.duplicateGTIN {
            guard let existing = try repository.fetchProduct(gtin: resolved.gtin)
            else {
                throw InventoryError.duplicateGTIN
            }
            return existing
        }
    }

    /// Fallback rule for the session location (Grilling #17): the
    /// stored location while it exists, otherwise the seeded
    /// „Keller" default, otherwise the first location. `nil` only
    /// when there are no locations at all.
    static func resolveSessionLocation(
        storedID: UUID?,
        locations: [Location]
    ) -> Location? {
        if let storedID, let stored = locations.first(where: { $0.id == storedID }) {
            return stored
        }
        if let keller = locations.first(where: { $0.name == "Keller" }) {
            return keller
        }
        return locations.first
    }
}
