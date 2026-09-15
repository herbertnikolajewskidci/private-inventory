import Foundation
@testable import PrivateInventory

/// A scriptable stand-in for `CatalogSource` (tests only).
///
/// Returns canned outcomes in call order and records every call, so
/// tests can prove call counts and chain order without a network.
/// When the outcome list is exhausted, further calls answer with a
/// clean not-found.
actor StubCatalogSource: CatalogSource {
    /// One scripted answer of the stub.
    enum Outcome: Sendable {
        /// The source resolves the GTIN to this product.
        case product(ResolvedProduct)
        /// The source has no data for the GTIN (clean not-found).
        case notFound
        /// The source is unusable for the request (thrown error).
        case error(CatalogError)
    }

    /// The name of the stub, mirroring its role in the chain
    /// ("mcp", "search", "obf").
    let name: String
    /// How often the stub was called.
    private(set) var callCount = 0
    /// The GTINs the stub was called with, in call order.
    private(set) var calledGtins: [String] = []

    private var outcomes: [Outcome]

    /// - Parameters:
    ///   - name: the role of the stub in the chain.
    ///   - outcomes: the scripted answers, consumed in call order.
    init(name: String, outcomes: [Outcome]) {
        self.name = name
        self.outcomes = outcomes
    }

    func resolve(gtin: String) async throws -> ResolvedProduct? {
        callCount += 1
        calledGtins.append(gtin)
        let outcome = outcomes.indices.contains(callCount - 1)
            ? outcomes[callCount - 1]
            : .notFound
        switch outcome {
        case let .product(product):
            return product
        case .notFound:
            return nil
        case let .error(error):
            throw error
        }
    }
}

/// A sample `ResolvedProduct` for stub outcomes (tests only).
func stubProduct(
    gtin: String,
    name: String,
    brand: String = "Mühle",
    source: ProductSource = .mcp,
    cacheTTL: TimeInterval? = nil
) -> ResolvedProduct {
    ResolvedProduct(
        gtin: gtin,
        name: name,
        brand: brand,
        imageURL: nil,
        source: source,
        cacheTTL: cacheTTL
    )
}

/// A test clock behind a Sendable reference: the `now` closure of a
/// `CatalogLookup` reads from it, and tests advance it to control
/// cache expiry deterministically.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    /// The current test time.
    var current: Date {
        lock.withLock { date }
    }

    /// Advances the test time.
    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

/// A harness for `CatalogLookup` tests: an in-memory GRDB cache on
/// a fresh inventory database, stub sources and a controllable
/// clock (no network, no real time).
struct CatalogLookupHarness {
    /// The sample GTIN the tests resolve.
    static let gtin = "4000000000001"
    /// The start of test time (the clock the harness starts at).
    static let startTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// The catalog cache under the lookup.
    let cache: GRDBCatalogCache
    /// The lookup orchestrator under test.
    let lookup: CatalogLookup
    /// The clock the lookup reads; advance it to test expiry.
    let clock: TestClock
    /// The inventory repository behind the lookup (queue tests).
    let repository: GRDBInventoryRepository

    init(sources: [StubCatalogSource], clock: TestClock = TestClock(startTime)) throws {
        let inventory = try TestInventory()
        cache = GRDBCatalogCache(database: inventory.database)
        self.clock = clock
        repository = inventory.repository
        lookup = CatalogLookup(
            cache: cache,
            sources: sources,
            repository: repository,
            now: { clock.current }
        )
    }
}
