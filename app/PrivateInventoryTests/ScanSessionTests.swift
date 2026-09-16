import Foundation
@testable import PrivateInventory
import Testing

/// Scan-Session Core (ADR-0008, Ticket #18): Jeder Scan bucht still am
/// Sitzungs-Standort — lokales Produkt schlägt den Katalogcache, ein
/// Cache-Treffer bucht direkt, alles andere wird gequeued.
struct ScanSessionTests {
    private let gtinA = "4000000000001"
    private let gtinB = "4000000000002"

    /// Fixtur von `makeSession`: frisches In-Memory-Inventar,
    /// Session am Keller, der Keller (Sitzungs-Standort).
    private struct SessionFixture {
        let inventory: TestInventory
        let session: ScanSession
        let cellar: Location
    }

    /// Frisches In-Memory-Inventar plus Lookup und Session am Keller;
    /// `spawnQueueRun` wird injiziert (Determinismus, kein Background-Task).
    private func makeSession(
        sources: [StubCatalogSource],
        spawnQueueRun: (@Sendable () -> Void)? = nil
    ) throws -> SessionFixture {
        let inventory = try TestInventory()
        let cellar = try #require(try inventory.cellar())
        let cache = GRDBCatalogCache(database: inventory.database)
        let lookup = CatalogLookup(cache: cache, sources: sources, repository: inventory.repository)
        let session = ScanSession(
            sessionLocationID: cellar.id,
            repository: inventory.repository,
            lookup: lookup,
            spawnQueueRun: spawnQueueRun
        )
        return SessionFixture(inventory: inventory, session: session, cellar: cellar)
    }

    /// Lokales Produkt schlägt den Katalogcache: Der Scan bucht sofort,
    /// die Kette wird nicht aufgerufen, die Queue bleibt leer.
    /// Given: manuell angelegtes Produkt, not-found-Source, Keller
    /// When:  scan(gtin:)
    /// Then:  .booked, Bestand Keller = 1, Source nie aufgerufen, Queue leer
    @Test func localProductBeatsCacheAndBooksAtSessionLocation() async throws {
        // Given
        let source = StubCatalogSource(name: "mcp", outcomes: [.notFound])
        let fixture = try makeSession(sources: [source])
        let local = try fixture.inventory.repository.createProduct(
            TestInventory.product(gtin: gtinA, name: "Mehl")
        )
        // When
        let outcome = try await fixture.session.scan(gtin: gtinA)
        // Then
        guard case let .booked(product, level) = outcome else {
            Issue.record("Erwartet .booked, bekommen \(outcome)")
            return
        }
        #expect(product == local)
        #expect(level.productID == local.id)
        #expect(level.locationID == fixture.cellar.id)
        #expect(level.quantity == 1)
        #expect(await source.callCount == 0)
        #expect(try fixture.inventory.repository.fetchUnresolvedScans().isEmpty)
    }

    /// Cache-Treffer: Der Scan legt das Produkt mit den aufgelösten Daten an
    /// und bucht +1 am Sitzungs-Standort.
    /// Given: auflösende Source, ansonsten leeres Inventar, Keller
    /// When:  scan(gtin:)
    /// Then:  .booked, Produkt mit aufgelöstem Namen, Marke, Quelle .mcp,
    ///        Bestand Keller = 1
    @Test func cacheHitCreatesProductAndBooksAtSessionLocation() async throws {
        // Given
        let source = StubCatalogSource(
            name: "mcp",
            outcomes: [.product(stubProduct(gtin: gtinA, name: "Mehl", brand: "Mühle"))]
        )
        let fixture = try makeSession(sources: [source])
        // When
        let outcome = try await fixture.session.scan(gtin: gtinA)
        // Then
        guard case .booked = outcome else {
            Issue.record("Erwartet .booked, bekommen \(outcome)")
            return
        }
        let stored = try #require(try fixture.inventory.repository.fetchProduct(gtin: gtinA))
        #expect(stored.name == "Mehl")
        #expect(stored.brand == "Mühle")
        #expect(stored.source == .mcp)
        let level = try #require(try fixture.inventory.repository.fetchStockLevel(
            productID: stored.id, locationID: fixture.cellar.id
        ))
        #expect(level.quantity == 1)
    }

    /// Duplicate-GTIN-Race: Bei `duplicateGTIN` wird das existierende Produkt
    /// wiederverwendet — kein zweites Produkt, Buchung am ID des existierenden Produkts.
    /// Given: Repository-Stub (nil dann existent, duplicateGTIN), auflösende Source
    /// When:  scan(gtin:)
    /// Then:  .booked mit dem existierenden Produkt, scanIn mit dessen ID und dem Sitzungs-Standort
    @Test func cacheHitReusesExistingProductAfterDuplicateRace() async throws {
        // Given
        let existing = TestInventory.product(gtin: gtinA, name: "Mehl")
        let repository = RecordingRepository(fetchProductAnswers: [nil, existing], createProductThrows: true)
        let source = StubCatalogSource(
            name: "mcp", outcomes: [.product(stubProduct(gtin: gtinA, name: "Mehl", brand: "Mühle"))]
        )
        let scratch = try TestInventory()
        let sessionLocation = UUID()
        let session = ScanSession(
            sessionLocationID: sessionLocation,
            repository: repository,
            lookup: CatalogLookup(cache: GRDBCatalogCache(database: scratch.database), sources: [source])
        )
        // When
        let outcome = try await session.scan(gtin: gtinA)
        // Then
        guard case let .booked(product, level) = outcome else {
            Issue.record("Erwartet .booked, bekommen \(outcome)")
            return
        }
        #expect(product == existing)
        #expect(level.quantity == 1)
        #expect(repository.createProductCallCount == 1)
        let scanInCalls = repository.scanInArguments
        #expect(scanInCalls.count == 1)
        #expect(scanInCalls.first?.productID == existing.id)
        #expect(scanInCalls.first?.locationID == sessionLocation)
    }

    /// Sauberer Miss: Der Scan bucht sofort einen Ungelösten Scan (eigene
    /// Queue-Zeile, Menge 1, am Sitzungs-Standort), kein Produkt, Trigger ① einmal.
    /// Given: not-found-Source, aufzeichnendes spawnQueueRun-Double
    /// When:  scan(gtin:)
    /// Then:  .queued, eine Queue-Zeile (Menge 1, am Keller), kein Produkt,
    ///        Trigger genau einmal
    @Test func cleanMissBooksUnresolvedScanAndKicksQueueRun() async throws {
        // Given
        let recorder = QueueRunRecorder()
        let fixture = try makeSession(
            sources: [StubCatalogSource(name: "mcp", outcomes: [.notFound])],
            spawnQueueRun: { recorder.record() }
        )
        // When
        let outcome = try await fixture.session.scan(gtin: gtinA)
        // Then
        guard case let .queued(scan) = outcome else {
            Issue.record("Erwartet .queued, bekommen \(outcome)")
            return
        }
        let queue = try fixture.inventory.repository.fetchUnresolvedScans()
        #expect(queue.count == 1)
        #expect(queue.first?.id == scan.id)
        #expect(scan.gtin == gtinA)
        #expect(scan.locationID == fixture.cellar.id)
        #expect(scan.quantity == 1)
        #expect(try fixture.inventory.repository.fetchProduct(gtin: gtinA) == nil)
        #expect(recorder.callCount == 1)
    }

    /// Lookup-Fehler (Netz down): Der Scan-Flow bricht nicht — die GTIN
    /// wird wie ein sauberer Miss gequeued, kein Fehler wandert nach oben.
    /// Given: Source wirft CatalogError.network, Keller
    /// When:  scan(gtin:)
    /// Then:  .queued, eine Queue-Zeile am Keller, kein Throw
    @Test func thrownLookupQueuesScanAndDoesNotBreakTheFlow() async throws {
        // Given
        let recorder = QueueRunRecorder()
        let fixture = try makeSession(
            sources: [StubCatalogSource(name: "mcp", outcomes: [.error(CatalogError.network(reason: "offline"))])],
            spawnQueueRun: { recorder.record() }
        )
        // When
        let outcome = try await fixture.session.scan(gtin: gtinA)
        // Then
        guard case .queued = outcome else {
            Issue.record("Erwartet .queued, bekommen \(outcome)")
            return
        }
        let queue = try fixture.inventory.repository.fetchUnresolvedScans()
        #expect(queue.count == 1)
        #expect(queue.first?.locationID == fixture.cellar.id)
        #expect(recorder.callCount == 1)
    }

    /// Wiederholte Scans derselben ungelösten GTIN bleiben separate Queue-
    /// Zeilen (eine pro Scan, je Menge 1) — Aggregation ist eine UI-Angelegenheit.
    /// Given: not-found-Source, Keller
    /// When:  scan(gtin:) zweimal mit derselben GTIN
    /// Then:  zwei Queue-Zeilen, je Menge 1, verschiedene IDs
    @Test func repeatedScansOfTheSameUnresolvedGtinStaySeparateRows() async throws {
        // Given
        let recorder = QueueRunRecorder()
        let fixture = try makeSession(
            sources: [StubCatalogSource(name: "mcp", outcomes: [.notFound])],
            spawnQueueRun: { recorder.record() }
        )
        // When
        _ = try await fixture.session.scan(gtin: gtinB)
        _ = try await fixture.session.scan(gtin: gtinB)
        // Then
        let queue = try fixture.inventory.repository.fetchUnresolvedScans()
        #expect(queue.count == 2)
        #expect(queue.allSatisfy { $0.gtin == gtinB })
        #expect(queue.allSatisfy { $0.quantity == 1 })
        #expect(Set(queue.map(\.id)).count == 2)
    }

    /// Gelöschter Sitzungs-Standort: Der Scan wirft InventoryError.missingParent,
    /// statt still an einem nicht existierenden Ort zu buchen.
    /// Given: Sitzungs-Standort-UUID ohne Location, not-found-Source
    /// When:  scan(gtin:)
    /// Then:  InventoryError.missingParent
    @Test func scanAtDeletedSessionLocationThrowsMissingParent() async throws {
        // Given
        let inventory = try TestInventory()
        let session = ScanSession(
            sessionLocationID: UUID(),
            repository: inventory.repository,
            lookup: CatalogLookup(
                cache: GRDBCatalogCache(database: inventory.database),
                sources: [StubCatalogSource(name: "mcp", outcomes: [.notFound])]
            )
        )
        // When / Then
        await #expect(throws: InventoryError.missingParent) {
            try await session.scan(gtin: gtinA)
        }
    }

    /// Fallback-Regel: Solange der gespeicherte Sitzungs-Standort existiert, gilt er.
    /// Given: Keller + Vorratsschrank, gespeicherte ID = Vorratsschrank
    /// When:  resolveSessionLocation
    /// Then:  Vorratsschrank
    @Test func resolveSessionLocationUsesTheStoredLocationWhileItExists() {
        // Given
        let cellar = Location(name: "Keller")
        let pantry = Location(name: "Vorratsschrank")
        // When
        let resolved = ScanSession.resolveSessionLocation(storedID: pantry.id, locations: [cellar, pantry])
        // Then
        #expect(resolved == pantry)
    }

    /// Fallback-Regel: Ohne gespeicherten Standort (nil) oder mit unbekannter
    /// ID gilt der geseedete Default „Keller".
    /// Given: Vorratsschrank + Keller, gespeicherte ID nil bzw. unbekannt
    /// When:  resolveSessionLocation
    /// Then:  Keller in beiden Fällen
    @Test func resolveSessionLocationFallsBackToKellerWithoutStoredLocation() {
        // Given
        let cellar = Location(name: "Keller")
        let pantry = Location(name: "Vorratsschrank")
        let locations = [pantry, cellar]
        // When / Then
        let withoutStored = ScanSession.resolveSessionLocation(storedID: nil, locations: locations)
        #expect(withoutStored == cellar)
        let withUnknown = ScanSession.resolveSessionLocation(storedID: UUID(), locations: locations)
        #expect(withUnknown == cellar)
    }

    /// Fallback-Regel: Ist „Keller" gelöscht (nicht in der Standortliste),
    /// gilt der erste Standort der Liste.
    /// Given: Regal + Vorratsschrank (kein Keller), unbekannte ID
    /// When:  resolveSessionLocation
    /// Then:  Regal (erster der Liste)
    @Test func resolveSessionLocationFallsBackToFirstWhenKellerIsDeleted() {
        // Given
        let shelf = Location(name: "Regal")
        let pantry = Location(name: "Vorratsschrank")
        // When
        let resolved = ScanSession.resolveSessionLocation(storedID: UUID(), locations: [shelf, pantry])
        // Then
        #expect(resolved == shelf)
    }

    /// Fallback-Regel: Ohne jegliche Standorte gibt es keinen Sitzungs-Standort.
    /// Given: leere Standortliste
    /// When:  resolveSessionLocation
    /// Then:  nil
    @Test func resolveSessionLocationReturnsNilWhenNoLocationsExist() {
        // Given / When
        let resolved = ScanSession.resolveSessionLocation(storedID: UUID(), locations: [])
        // Then
        #expect(resolved == nil)
    }
}

/// Aufzeichnendes spawnQueueRun-Double für Trigger ① (handgeschriebenes Stub, NSLock, @unchecked Sendable).
private final class QueueRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var callCount: Int {
        lock.withLock { count }
    }

    func record() {
        lock.withLock { count += 1 }
    }
}

/// Aufzeichnendes `InventoryRepository`-Stub (ADR-0006) für den duplicate-
/// GTIN-Race-Test: skriptierte `fetchProduct`-Antworten, `createProduct` wirft
/// `duplicateGTIN`, `scanIn` zeichnet auf; alles andere `fatalError`.
private final class RecordingRepository: InventoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var fetchProductCalls = 0
    private var createProductCalls = 0
    private var scanInCalls: [(productID: UUID, locationID: UUID)] = []
    private let fetchProductAnswers: [Product?]
    private let createProductThrows: Bool
    init(fetchProductAnswers: [Product?], createProductThrows: Bool) {
        self.fetchProductAnswers = fetchProductAnswers
        self.createProductThrows = createProductThrows
    }

    var createProductCallCount: Int {
        lock.withLock { createProductCalls }
    }

    var scanInArguments: [(productID: UUID, locationID: UUID)] {
        lock.withLock { scanInCalls }
    }

    func fetchProduct(gtin _: String) throws -> Product? {
        lock.withLock {
            let answer = fetchProductAnswers.indices.contains(fetchProductCalls)
                ? fetchProductAnswers[fetchProductCalls]
                : nil
            fetchProductCalls += 1
            return answer
        }
    }

    func createProduct(_ product: Product) throws -> Product {
        lock.withLock { createProductCalls += 1 }
        guard createProductThrows else { return product }
        throw InventoryError.duplicateGTIN
    }

    func scanIn(productID: UUID, locationID: UUID) throws -> StockLevel {
        lock.withLock {
            scanInCalls.append((productID: productID, locationID: locationID))
        }
        return try StockLevel(productID: productID, locationID: locationID, quantity: 1)
    }

    /// Der Race-Test erreicht diese Methoden nicht.
    func fetchLocations() throws -> [Location] {
        fatalError()
    }

    func withdraw(productID _: UUID, locationID _: UUID, amount _: Int) throws -> StockLevel {
        fatalError()
    }

    func transfer(
        productID _: UUID, fromLocationID _: UUID, toLocationID _: UUID, amount _: Int
    ) throws -> (source: StockLevel, destination: StockLevel) {
        fatalError()
    }

    func fetchStockLevels(productID _: UUID?) throws -> [StockLevel] {
        fatalError()
    }

    func fetchStockLevel(productID _: UUID, locationID _: UUID) throws -> StockLevel? {
        fatalError()
    }

    func fetchUnresolvedScans() throws -> [UnresolvedScan] {
        fatalError()
    }

    func recordUnresolvedScan(_: UnresolvedScan) throws -> UnresolvedScan {
        fatalError()
    }

    func deleteUnresolvedScan(id _: UUID) throws {
        fatalError()
    }

    func bookUnresolvedScan(scanID _: UUID, productID _: UUID) throws -> StockLevel {
        fatalError()
    }

    func createGTINAlias(gtin _: String, productID _: UUID) throws {
        fatalError()
    }

    func bindGTIN(
        scannedGTIN _: String,
        product _: Product
    ) throws -> (product: Product, bookedRows: Int) {
        fatalError()
    }
}
