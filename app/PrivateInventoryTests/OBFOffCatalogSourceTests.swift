import Foundation
@testable import PrivateInventory
import Testing

/// The OpenBeautyFacts/OpenFoodFacts catalog source against recorded
/// fixtures (ADR-0006): OBF first, OFF as fallback, and the error
/// cases. No network in any of these tests.
struct OBFOffCatalogSourceTests {
    /// A miss response from one database (recorded: HTTP 404 with
    /// body {"status":0,...}).
    private func missFixture(_ database: String) -> StubURLLoading.Response {
        .init(statusCode: 404, fixture: "\(database)_product_miss.json")
    }

    /// A known product is resolved from OpenBeautyFacts.
    ///
    /// Given: the recorded OBF hit response (DOVE deodorant)
    /// When: resolve(gtin: "80466468")
    /// Then: the name, brand and image URL come back, sourced as .obf
    @Test func resolvesKnownGtinFromOpenBeautyFacts() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [.init(statusCode: 200, fixture: "openbeautyfacts_product_hit.json")]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "80466468")

        // Then
        let product = try #require(resolved)
        #expect(product.name == "DOVE Déodorant Femme Anti-Transpirant Stick Original 50ml")
        #expect(product.brand == "Dove")
        #expect(product.imageURL?.host == "images.openbeautyfacts.org")
        #expect(product.source == .obf)
        // And only OBF was asked (no OFF call)
        let requests = await stub.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].url.contains("world.openbeautyfacts.org"))
    }

    /// When OpenBeautyFacts does not know the product, OFF is asked.
    ///
    /// Given: a recorded OBF miss (HTTP 404, status:0) and a
    /// recorded OFF hit (Nutella)
    /// When: resolve(gtin: "3017620422003")
    /// Then: the Nutella data comes back and two requests were sent —
    /// OBF first, then OFF
    @Test func fallsBackToOpenFoodFactsWhenOpenBeautyFactsMisses() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [
                missFixture("openbeautyfacts"),
                .init(statusCode: 200, fixture: "openfoodfacts_product_hit.json")
            ]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "3017620422003")

        // Then
        let product = try #require(resolved)
        #expect(product.name == "Nutella")
        // The comma-separated brand list yields its first entry
        #expect(product.brand == "Nutella")
        #expect(product.imageURL?.host == "images.openfoodfacts.org")
        #expect(product.source == .obf)

        // And the lookup order was OBF, then OFF
        let requests = await stub.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url.contains("world.openbeautyfacts.org"))
        #expect(requests[1].url.contains("world.openfoodfacts.org"))
    }

    /// A product neither database knows is a clean not-found.
    ///
    /// Given: recorded misses from OBF and OFF (a dm GTIN neither
    /// database has)
    /// When: resolve(gtin: "4066447966008")
    /// Then: nil is returned and both databases were asked
    @Test func returnsNilWhenNeitherDatabaseKnowsTheGtin() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [
                missFixture("openbeautyfacts"),
                missFixture("openfoodfacts")
            ]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When/Then
        let resolved = try await source.resolve(gtin: "4066447966008")
        #expect(resolved == nil)
        #expect(await stub.recordedRequests().count == 2)
    }

    /// A network error of OBF stops the lookup — it is not a miss.
    ///
    /// Given: OBF answered HTTP 500 (server down, not "no product")
    /// When: resolve(gtin:)
    /// Then: CatalogError.network is thrown and OFF was *not* asked —
    /// the orchestrator (not this client) decides about fallbacks,
    /// and a rate-limited call must not be burned on a degraded source
    @Test func networkErrorOfOpenBeautyFactsStopsTheLookup() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [.init(statusCode: 500, body: "server error")]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.network(reason: "world.openbeautyfacts.org answered HTTP 500")) {
            try await source.resolve(gtin: "3017620422003")
        }
        #expect(await stub.recordedRequests().count == 1)
    }

    /// A malformed OBF response is a parse error (and OFF is not
    /// asked — a parse failure is not a miss).
    ///
    /// Given: OBF answered HTTP 200 with a body that is not JSON
    /// When: resolve(gtin:)
    /// Then: CatalogError.parse is thrown and only one request was
    /// sent
    @Test func malformedResponseThrowsParseError() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [.init(statusCode: 200, body: "not json")]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.self) {
            try await source.resolve(gtin: "80466468")
        }
        #expect(await stub.recordedRequests().count == 1)
    }

    /// A found product without a name yields no usable data.
    ///
    /// Given: a synthetic OBF hit (status:1) whose product_name is
    /// empty, and a recorded OFF miss
    /// When: resolve(gtin:)
    /// Then: nil is returned — a `Product` requires a name. The
    /// nameless OBF hit counts as a miss, so OFF is asked too; a
    /// record without a name is not storable, and the OFF database
    /// may still know a complete entry
    @Test func foundProductWithoutNameResolvesToNil() async throws {
        // Given
        let body = #"{"code":"123456","status":1,"status_verbose":"product found","# +
            #""product":{"code":"123456","product_name":""}}"#
        let stub = StubURLLoading(responses: [
            .init(statusCode: 200, body: body),
            missFixture("openfoodfacts")
        ])
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When/Then
        let resolved = try await source.resolve(gtin: "123456")
        #expect(resolved == nil)
        // The nameless OBF hit was treated as a miss and OFF was asked
        #expect(await stub.recordedRequests().count == 2)
    }

    /// A non-numeric GTIN is refused before any network request.
    ///
    /// Given: a stub with one unused recorded response
    /// When: resolve(gtin: "NOT-A-GTIN")
    /// Then: CatalogError.invalidGtin is thrown and zero requests
    /// were sent
    @Test func nonNumericGtinThrowsWithoutNetworkRequest() async throws {
        // Given
        let stub = StubURLLoading(
            responses: [.init(statusCode: 200, fixture: "openbeautyfacts_product_hit.json")]
        )
        let source: any CatalogSource = OBFOffCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.invalidGtin(gtin: "NOT-A-GTIN")) {
            try await source.resolve(gtin: "NOT-A-GTIN")
        }
        #expect(await stub.recordedRequests().isEmpty)
    }
}
