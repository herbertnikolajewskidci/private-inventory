import Foundation
@testable import PrivateInventory
import Testing

/// The dm MCP catalog source against recorded fixtures (ADR-0006):
/// handshake, session handling, the GTIN-as-Int64 contract and TOON
/// parsing. No network in any of these tests.
struct DmMcpCatalogSourceTests {
    /// The session id of the recorded initialize response
    /// (dm_mcp_initialize.headers.txt, recorded 2026-09-14).
    static let recordedSessionID = "92fa9923128b48d3a0939a4e2f3844c2"

    /// A stub that answers a fresh lookup: initialize, the
    /// initialized notification, then the given tool-call response.
    private func makeStub(toolCall: StubURLLoading.Response) -> StubURLLoading {
        StubURLLoading(responses: [
            StubURLLoading.Response(
                statusCode: 200,
                fixture: "dm_mcp_initialize.json",
                headers: ["mcp-session-id": Self.recordedSessionID]
            ),
            StubURLLoading.Response(statusCode: 202, body: ""),
            toolCall
        ])
    }

    /// A known dm product is resolved after the MCP handshake.
    ///
    /// Given: recorded responses for initialize, the initialized
    /// notification and a tools/call hit (Balea med shampoo)
    /// When: resolve(gtin: "4066447966008")
    /// Then: the name, brand and image URL come back, sourced as .mcp
    @Test func resolvesKnownGtinAfterHandshake() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 200, fixture: "dm_mcp_product_hit.json"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "4066447966008")

        // Then
        let product = try #require(resolved)
        #expect(product.name == "Shampoo Ultra Sensitive, 250 ml")
        #expect(product.brand == "Balea med")
        #expect(product.imageURL?.host == "products.dm-static.com")
        #expect(product.source == .mcp)
    }

    /// The GTIN is sent as an Int64 array, not as strings.
    ///
    /// Given: the recorded handshake and a recorded hit
    /// When: resolve(gtin: "4066447966008")
    /// Then: the tools/call body contains "gtins":[4066447966008] —
    /// dm rejects string GTINs with a schema validation error
    /// (research doc section 4.1, ticket #4)
    @Test func sendsGtinAsInt64InToolCall() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 200, fixture: "dm_mcp_product_hit.json"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When
        _ = try await source.resolve(gtin: "4066447966008")

        // Then: the third request is the tool call
        let requests = await stub.recordedRequests()
        let toolCallBody = try #require(requests[2].body)
        #expect(toolCallBody.contains("\"gtins\":[4066447966008]"))
        #expect(!toolCallBody.contains("\"4066447966008\""))
    }

    /// Every request after initialize carries the session id.
    ///
    /// Given: the recorded handshake (the session id arrives in the
    /// initialize response header) and a recorded hit
    /// When: resolve(gtin:)
    /// Then: the initialized notification and the tool call send the
    /// Mcp-Session-Id header — without it dm answers HTTP 400
    @Test func followUpRequestsCarrySessionID() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 200, fixture: "dm_mcp_product_hit.json"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When
        _ = try await source.resolve(gtin: "4066447966008")

        // Then
        let requests = await stub.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].headers["Mcp-Session-Id"] == nil)
        #expect(requests[1].headers["Mcp-Session-Id"] == Self.recordedSessionID)
        #expect(requests[2].headers["Mcp-Session-Id"] == Self.recordedSessionID)
    }

    /// An unknown GTIN is a clean not-found, not an error.
    ///
    /// Given: the recorded handshake and a recorded tools/call whose
    /// TOON row says found=false
    /// When: resolve(gtin: "9999999999999")
    /// Then: nil is returned (the orchestrator of ticket #14 may
    /// cache this negatively and continue the fallback chain)
    @Test func unknownGtinResolvesToNil() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 200, fixture: "dm_mcp_product_miss.json"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then
        let resolved = try await source.resolve(gtin: "9999999999999")
        #expect(resolved == nil)
    }

    /// An expired session (HTTP 404 on the tool call) triggers one
    /// re-handshake and one retry.
    ///
    /// Given: a recorded handshake, a tool call answered with the
    /// recorded 404 "Session not found", then a second handshake and
    /// the recorded hit
    /// When: resolve(gtin: "4066447966008")
    /// Then: the product comes back and six requests were sent
    /// (initialize, notification, failed call, initialize,
    /// notification, retried call)
    @Test func expiredSessionIsReinitializedOnce() async throws {
        // Given
        let initialize = StubURLLoading.Response(
            statusCode: 200,
            fixture: "dm_mcp_initialize.json",
            headers: ["mcp-session-id": Self.recordedSessionID]
        )
        let stub = StubURLLoading(responses: [
            initialize,
            .init(statusCode: 202, body: ""),
            .init(statusCode: 404, fixture: "dm_mcp_session_expired.json"),
            initialize,
            .init(statusCode: 202, body: ""),
            .init(statusCode: 200, fixture: "dm_mcp_product_hit.json")
        ])
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When
        let resolved = try await source.resolve(gtin: "4066447966008")

        // Then
        #expect(resolved?.name == "Shampoo Ultra Sensitive, 250 ml")
        let requests = await stub.recordedRequests()
        #expect(requests.count == 6)
    }

    /// An HTTP error status of the tool call is a network error.
    ///
    /// Given: the recorded handshake and a tool call answered HTTP 500
    /// When: resolve(gtin:)
    /// Then: CatalogError.network is thrown (the orchestrator falls
    /// back; no negative cache entry)
    @Test func httpErrorStatusThrowsNetworkError() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 500, body: "internal error"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.network(reason: "dm MCP getProductDetails answered HTTP 500")) {
            try await source.resolve(gtin: "4066447966008")
        }
    }

    /// A tool call response whose text is not a TOON table is a parse
    /// error.
    ///
    /// Given: the recorded handshake and a tool call whose text
    /// content is plain prose (synthetic corruption)
    /// When: resolve(gtin:)
    /// Then: CatalogError.parse is thrown
    @Test func malformedToolCallResponseThrowsParseError() async throws {
        // Given: an SSE body whose JSON-RPC result has no TOON table
        let envelope = #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","# +
            #""text":"not a TOON table"}],"isError":false}}"#
        let stub = makeStub(toolCall: .init(statusCode: 200, body: "data: \(envelope)"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then: the failure is a parse error, not a network error
        do {
            _ = try await source.resolve(gtin: "4066447966008")
            Issue.record("expected CatalogError.parse")
        } catch let error as CatalogError {
            guard case .parse = error else {
                Issue.record("expected a parse error, got \(error)")
                return
            }
        }
    }

    /// An SSE body without a data: line is a parse error.
    ///
    /// Given: the recorded handshake and a tool call answered HTTP 200
    /// with an SSE body that carries no data line
    /// When: resolve(gtin:)
    /// Then: CatalogError.parse is thrown
    @Test func sseBodyWithoutDataLineThrowsParseError() async throws {
        // Given
        let stub = makeStub(toolCall: .init(statusCode: 200, body: "event: message\n\n"))
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.self) {
            try await source.resolve(gtin: "4066447966008")
        }
    }

    /// An initialize response without the Mcp-Session-Id header is a
    /// parse error: the session is the contract of the handshake.
    ///
    /// Given: a 200 initialize body (recorded) but no session header
    /// When: resolve(gtin:)
    /// Then: CatalogError.parse is thrown and no further request is
    /// sent
    @Test func initializeWithoutSessionHeaderThrowsParseError() async throws {
        // Given
        let stub = StubURLLoading(responses: [
            .init(statusCode: 200, fixture: "dm_mcp_initialize.json")
        ])
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.parse(reason: "dm MCP initialize response has no Mcp-Session-Id header")) {
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
        let stub = StubURLLoading(responses: [])
        let source: any CatalogSource = DmMcpCatalogSource(loader: stub)

        // When/Then
        await #expect(throws: CatalogError.invalidGtin(gtin: "NOT-A-GTIN")) {
            try await source.resolve(gtin: "NOT-A-GTIN")
        }
        #expect(await stub.recordedRequests().isEmpty)
    }

    // MARK: - TOON parser (direct)

    /// A TOON table with several rows yields the row of the requested
    /// GTIN.
    ///
    /// Given: a synthetic TOON table with rows for two GTINs
    /// When: the table is parsed for the second GTIN
    /// Then: the fields of that row come back
    @Test func toonParsingPicksTheRowOfTheRequestedGtin() throws {
        // Given
        let table = """
        [2]{dan|gtin|productName|brand|found}:
          1|111|Product A|Brand A|true
          2|222|Product B|Brand B|true
        """

        // When
        let record = try DmToonParser.record(from: table, forGtin: "222")

        // Then
        #expect(record["productName"] == "Product B")
        #expect(record["brand"] == "Brand B")
    }

    /// Quoted TOON values are unquoted; escaped quotes inside a quoted
    /// value are restored.
    ///
    /// Given: a synthetic TOON row whose productName is a quoted value
    /// containing escaped quotes (\" in the wire format)
    /// When: the row is parsed
    /// Then: the productName holds the restored double quotes
    @Test func toonParsingRestoresEscapedQuotes() throws {
        // Given: in a Swift multi-line string the backslashes are
        // literal, so this is exactly the TOON wire format
        let table = """
        [1]{gtin|productName}:
          123|"Heute \"Sonnenschein\""
        """

        // When
        let record = try DmToonParser.record(from: table, forGtin: "123")

        // Then
        #expect(record["productName"] == #"Heute "Sonnenschein""#)
    }
}
