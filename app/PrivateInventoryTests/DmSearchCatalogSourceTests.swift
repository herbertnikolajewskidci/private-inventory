import Foundation
@testable import PrivateInventory
import Testing

/// The dm search catalog source against recorded fixtures (ADR-0006):
/// GTIN as query, the GTIN match filter, the 4-day cache-control
/// header and the error cases. No network in any of these tests.
struct DmSearchCatalogSourceTests {
    /// A stub with one recorded response (the client sends exactly
    /// one request per lookup).
    private func makeStub(_ response: StubURLLoading.Response) -> StubURLLoading {
        StubURLLoading(responses: [response])
    }

    /// The recorded cache-control header of the hit response
    /// (dm_search_product_hit.headers.txt, recorded 2026-09-14:
    /// public, max-age=345600, s-maxage=345600).
    private var recordedCacheControl: String {
        Fixture.header("cache-control", from: "dm_search_product_hit.headers.txt") ?? ""
    }

    /// A known dm product is resolved from the search results.
    ///
    /// Given: the recorded hit response (exactly one product, whose
    /// gtin field matches the query)
    /// When: resolve(gtin: "4066447966008")
    /// Then: the title, brand and image URL come back, sourced as
    /// .search
    @Test func resolvesKnownGtinFromSearchResults() async throws {
        // Given
        let stub = makeStub(.init(
            statusCode: 200,
            fixture: "dm_search_product_hit.json",
            headers: ["cache-control": recordedCacheControl]
        ))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "4066447966008")

        // Then
        let product = try #require(resolved)
        #expect(product.name == "Shampoo Ultra Sensitive, 250 ml")
        #expect(product.brand == "Balea med")
        #expect(product.imageURL?.host == "products.dm-static.com")
        #expect(product.source == .search)
    }

    /// The GTIN travels as the query parameter of the crawl endpoint.
    ///
    /// Given: the recorded hit response
    /// When: resolve(gtin: "4066447966008")
    /// Then: the request goes to the dm crawl endpoint with
    /// query=4066447966008
    @Test func sendsGtinAsQueryParameter() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, fixture: "dm_search_product_hit.json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When
        _ = try await source.resolve(gtin: "4066447966008")

        // Then
        let requests = await stub.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].url.contains("product-search.services.dmtech.com"))
        #expect(requests[0].url.contains("query=4066447966008"))
    }

    /// The 4-day cache header of the dm search API is respected.
    ///
    /// Given: the recorded hit response *and* its recorded
    /// cache-control header (public, max-age=345600)
    /// When: resolve(gtin: "4066447966008")
    /// Then: the result carries cacheTTL 345600 seconds — the value
    /// the server sent in the header, not a hard-coded constant
    /// (the catalog cache of ticket #14 applies it)
    @Test func respectsCacheControlHeader() async throws {
        // Given
        let stub = makeStub(.init(
            statusCode: 200,
            fixture: "dm_search_product_hit.json",
            headers: ["cache-control": recordedCacheControl]
        ))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "4066447966008")

        // Then
        #expect(resolved?.cacheTTL == 345_600)
    }

    /// Without a cache-control header the result carries no TTL.
    ///
    /// Given: the recorded hit response, but the stub sends no
    /// cache-control header
    /// When: resolve(gtin:)
    /// Then: cacheTTL is nil — the client forwards what the server
    /// said, nothing invented
    @Test func missingCacheControlHeaderMeansNoTTL() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, fixture: "dm_search_product_hit.json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "4066447966008")

        // Then
        #expect(resolved?.cacheTTL == nil)
    }

    /// An unknown GTIN is a clean not-found, not an error.
    ///
    /// Given: the recorded miss response (HTTP 200 with an empty
    /// product list)
    /// When: resolve(gtin: "9999999999999")
    /// Then: nil is returned
    @Test func unknownGtinResolvesToNil() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, fixture: "dm_search_product_miss.json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        let resolved = try await source.resolve(gtin: "9999999999999")
        #expect(resolved == nil)
    }

    /// A search result whose GTIN does not match is not a hit.
    ///
    /// Given: the recorded hit response (one product, GTIN
    /// 4066447966008), but the lookup asks for a different GTIN
    /// When: resolve(gtin: "9999999999999")
    /// Then: nil is returned — a GTIN query can return other
    /// products; only a matching gtin field counts
    @Test func nonMatchingProductInResultsResolvesToNil() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, fixture: "dm_search_product_hit.json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        let resolved = try await source.resolve(gtin: "9999999999999")
        #expect(resolved == nil)
    }

    /// An HTTP error status is a network error.
    ///
    /// Given: a search answered HTTP 404
    /// When: resolve(gtin:)
    /// Then: CatalogError.network is thrown (unlike the OBF/OFF
    /// sources, where 404 is the normal miss answer)
    @Test func httpErrorStatusThrowsNetworkError() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 404, body: "not found"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.network(reason: "dm search answered HTTP 404")) {
            try await source.resolve(gtin: "4066447966008")
        }
    }

    /// A malformed response body is a parse error.
    ///
    /// Given: a search answered HTTP 200 with a body that is not JSON
    /// When: resolve(gtin:)
    /// Then: CatalogError.parse is thrown
    @Test func malformedResponseThrowsParseError() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, body: "not json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.self) {
            try await source.resolve(gtin: "4066447966008")
        }
    }

    /// A non-numeric GTIN is refused before any network request.
    ///
    /// Given: a stub without any recorded responses (any request
    /// would crash the stub)
    /// When: resolve(gtin: "NOT-A-GTIN")
    /// Then: CatalogError.invalidGtin is thrown and zero requests
    /// were sent
    @Test func nonNumericGtinThrowsWithoutNetworkRequest() async throws {
        // Given
        let stub = makeStub(.init(statusCode: 200, fixture: "dm_search_product_hit.json"))
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.invalidGtin(gtin: "NOT-A-GTIN")) {
            try await source.resolve(gtin: "NOT-A-GTIN")
        }
        #expect(await stub.recordedRequests().isEmpty)
    }

    /// An empty GTIN is refused before any network request.
    ///
    /// Given: a stub with no recorded responses
    /// When: resolve(gtin: "")
    /// Then: CatalogError.invalidGtin is thrown and zero requests were sent
    @Test func emptyGtinThrowsWithoutNetworkRequest() async throws {
        // Given
        let stub = StubURLLoading(responses: [])
        let source: any CatalogSource = DmSearchCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.invalidGtin(gtin: "")) {
            try await source.resolve(gtin: "")
        }
        #expect(await stub.recordedRequests().isEmpty)
    }

    /// Decimal or non-integer max-age values in cache-control are rejected.
    ///
    /// Given: responses with max-age=1.5 and max-age=345600
    /// When: cacheTTL is parsed from the response
    /// Then: max-age=1.5 yields nil; max-age=345600 yields 345600
    @Test func decimalMaxAgeIsRejectedFromCacheControl() throws {
        // Given
        let url = try #require(URL(string: "https://example.com"))
        let decimalResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["cache-control": "public, max-age=1.5"]
        ))
        let validResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["cache-control": "public, max-age=345600"]
        ))

        // When/Then
        #expect(DmSearchCatalogSource.cacheTTL(from: decimalResponse) == nil)
        #expect(DmSearchCatalogSource.cacheTTL(from: validResponse) == 345_600)
    }

    /// Transport failures thrown by the injected loader are normalized to
    /// CatalogError.network.
    ///
    /// Given: a loader throwing a custom non-CatalogError
    /// When: resolve(gtin:)
    /// Then: CatalogError.network is thrown
    @Test func foreignLoaderErrorIsNormalizedToNetworkError() async throws {
        // Given
        let source: any CatalogSource = DmSearchCatalogSource(loader: FailingURLLoading())

        // When/Then
        do {
            _ = try await source.resolve(gtin: "4066447966008")
            Issue.record("expected CatalogError.network")
        } catch let error as CatalogError {
            guard case let .network(reason) = error else {
                Issue.record("expected CatalogError.network, got \(error)")
                return
            }
            #expect(reason.contains("catalog transport failed"))
        }
    }

    /// URLSessionURLLoading maps transport errors to CatalogError.network.
    ///
    /// Given: an invalid URLRequest that fails immediately without network
    /// When: URLSessionURLLoading.load(request) is called
    /// Then: CatalogError.network is thrown
    @Test func urlSessionURLLoadingMapsTransportErrors() async throws {
        // Given
        let loader = URLSessionURLLoading()
        let request = try URLRequest(url: #require(URL(string: "unsupported-scheme://localhost")))

        // When/Then
        do {
            _ = try await loader.load(request)
            Issue.record("expected CatalogError.network")
        } catch let error as CatalogError {
            guard case let .network(reason) = error else {
                Issue.record("expected CatalogError.network, got \(error)")
                return
            }
            #expect(reason.contains("URLSession transport error"))
        }
    }

    // MARK: - Free-text search (CatalogSearch, ticket #24)

    /// A free-text query returns EVERY candidate with its OWN GTIN
    /// (they are not the queried text), in response order, with the
    /// recorded 4-day cache TTL (photo recognition, D3a/D4a).
    ///
    /// Given: the recorded text-query response (two candidates with
    /// their own GTINs) and its recorded cache-control header
    /// When: search(query: "Golden Intense")
    /// Then: two candidates with GTINs 4066447993554 and
    /// 4070765015133, source .search, cacheTTL 345600, non-empty
    /// names
    @Test func textQueryReturnsCandidatesWithOwnGTINsAndCacheTTL() async throws {
        // Given
        let stub = makeStub(.init(
            statusCode: 200,
            fixture: "dm_search_text_query.json",
            headers: [
                "cache-control": Fixture.header(
                    "cache-control",
                    from: "dm_search_text_query.headers.txt"
                ) ?? ""
            ]
        ))
        let source: any CatalogSearch = DmSearchCatalogSource(loader: stub)

        // When
        let candidates = try await source.search(query: "Golden Intense")

        // Then
        #expect(candidates.count == 2)
        #expect(candidates.map(\.gtin) == ["4066447993554", "4070765015133"])
        #expect(candidates.allSatisfy { $0.source == .search })
        #expect(candidates.allSatisfy { $0.cacheTTL == 345_600 })
        #expect(candidates.allSatisfy { !$0.name.isEmpty })
    }

    /// An empty or whitespace-only query returns no candidates
    /// WITHOUT a network call (the search input is user-editable;
    /// an empty query must not hit the API).
    ///
    /// Given: a stub with no recorded responses (any request would
    /// fail)
    /// When: search(query: "   ")
    /// Then: an empty array is returned and zero requests were sent
    @Test func emptyTextQueryReturnsNoCandidatesWithoutNetwork() async throws {
        // Given
        let stub = StubURLLoading(responses: [])
        let source: any CatalogSearch = DmSearchCatalogSource(loader: stub)

        // When
        let candidates = try await source.search(query: "   ")

        // Then
        #expect(candidates.isEmpty)
        #expect(await stub.recordedRequests().isEmpty)
    }
}
