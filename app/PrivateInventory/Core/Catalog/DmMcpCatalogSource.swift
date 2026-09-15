import Foundation

/// Internal signal that the stored MCP session is expired (the server
/// answered the tool call with HTTP 404). `resolve(gtin:)` turns it
/// into one re-handshake and one retry; it never escapes the client.
private struct DmMcpSessionExpiredError: Error {}

/// Catalog source for the official dm MCP server (ADR-0002, first in
/// the lookup chain).
///
/// Speaks MCP over plain `URLSession` (Streamable HTTP transport, no
/// MCP framework). Sequence per lookup: `initialize` (the response
/// carries the `Mcp-Session-Id` header) →
/// `notifications/initialized` → `tools/call getProductDetails`.
///
/// The traps documented in `docs/research/dm-mcp-swift-anbindung.md`
/// are handled here:
/// - every follow-up request must carry the `Mcp-Session-Id` header
///   (without it the server answers HTTP 400);
/// - an expired session answers HTTP 404 — the client drops the
///   session, re-handshakes once and retries the call;
/// - `gtins` must be sent as `[Int64]` — strings fail the server's
///   JSON-schema validation;
/// - the product data is a TOON table (pipe-separated) inside the
///   tool result text, not a JSON object (`DmToonParser`).
actor DmMcpCatalogSource: CatalogSource {
    private let loader: any URLLoading
    private let endpoint = URL(string: "https://mcp.dm.de/mcp")!
    /// The protocol version the client asks for; the server may
    /// negotiate an older one (the answered version is then used).
    private let requestedProtocolVersion = "2025-06-18"
    private var negotiatedProtocolVersion: String?
    private var sessionID: String?
    private var requestID = 1

    init(loader: any URLLoading = URLSessionURLLoading()) {
        self.loader = loader
    }

    func resolve(gtin: String) async throws -> ResolvedProduct? {
        guard !gtin.isEmpty, gtin.allSatisfy({ $0.isNumber && $0.isASCII }), let gtinValue = Int64(gtin) else {
            throw CatalogError.invalidGtin(gtin: gtin)
        }
        try await ensureSession()

        do {
            return try await callProductDetails(gtin: gtin, gtinValue: gtinValue)
        } catch is DmMcpSessionExpiredError {
            // The session expired: one re-handshake, one retry
            // (research doc section 4.3). A second expiry in a row is
            // a transport problem, not a retryable one.
            sessionID = nil
            try await ensureSession()
            do {
                return try await callProductDetails(gtin: gtin, gtinValue: gtinValue)
            } catch is DmMcpSessionExpiredError {
                throw CatalogError.network(reason: "dm MCP session expired after re-handshake")
            }
        }
    }

    // MARK: - Handshake

    private func ensureSession() async throws {
        guard sessionID == nil else { return }
        sessionID = try await handshake()
    }

    /// Runs the MCP handshake and returns the new session id.
    private func handshake() async throws -> String {
        let request = baseRequest(
            body: DmMcpInitializeRequest(
                id: nextRequestID(), params: .init(protocolVersion: requestedProtocolVersion)
            ),
            timeout: 10
        )
        let (data, response) = try await load(request)
        guard response.statusCode == 200 else {
            throw CatalogError.network(reason: "dm MCP initialize answered HTTP \(response.statusCode)")
        }
        // The session id arrives in a response header; without it the
        // session contract of the handshake is broken.
        guard let sessionID = response.headerValue("mcp-session-id") else {
            throw CatalogError.parse(reason: "dm MCP initialize response has no Mcp-Session-Id header")
        }
        let envelope = try decodeCatalogJSON(
            DmMcpInitializeEnvelope.self, from: Self.sseJSON(from: data)
        )
        if let rpcError = envelope.error {
            throw CatalogError.network(
                reason: "dm MCP initialize JSON-RPC error \(rpcError.code): \(rpcError.message)"
            )
        }
        guard let result = envelope.result else {
            throw CatalogError.parse(reason: "dm MCP initialize response has no result")
        }
        negotiatedProtocolVersion = result.protocolVersion

        // Acknowledge the handshake (HTTP 202, empty body expected).
        let notification = baseRequest(
            body: DmMcpInitializedNotification(),
            timeout: 5,
            sessionID: sessionID
        )
        let (_, notificationResponse) = try await load(notification)
        guard notificationResponse.statusCode == 202 || notificationResponse.statusCode == 200 else {
            throw CatalogError.network(
                reason: "dm MCP initialized notification answered HTTP \(notificationResponse.statusCode)"
            )
        }
        return sessionID
    }

    // MARK: - Tool call

    private func callProductDetails(gtin: String, gtinValue: Int64) async throws -> ResolvedProduct? {
        guard let sessionID else {
            throw CatalogError.network(reason: "dm MCP session is missing")
        }
        let request = baseRequest(
            body: DmMcpToolCallRequest(
                id: nextRequestID(),
                params: .init(arguments: .init(gtins: [gtinValue]))
            ),
            timeout: 8,
            sessionID: sessionID
        )
        let (data, response) = try await load(request)
        if response.statusCode == 404 {
            // Expired or unknown session (research doc section 4.3).
            throw DmMcpSessionExpiredError()
        }
        guard response.statusCode == 200 else {
            throw CatalogError.network(
                reason: "dm MCP getProductDetails answered HTTP \(response.statusCode)"
            )
        }
        let envelope = try decodeCatalogJSON(
            DmMcpToolCallEnvelope.self, from: Self.sseJSON(from: data)
        )
        if let rpcError = envelope.error {
            throw CatalogError.network(
                reason: "dm MCP JSON-RPC error \(rpcError.code): \(rpcError.message)"
            )
        }
        guard let result = envelope.result else {
            throw CatalogError.parse(reason: "dm MCP tool call result is missing")
        }
        guard result.isError != true else {
            throw CatalogError.parse(reason: "dm MCP tool call flagged isError")
        }
        guard let text = result.content?.first(where: { $0.type == "text" })?.text else {
            throw CatalogError.parse(reason: "dm MCP tool call has no text content")
        }
        // The text is a JSON object whose "result" field holds the
        // TOON table (research doc section 4.5).
        let details = try decodeCatalogJSON(DmMcpProductDetailsPayload.self, from: Data(text.utf8))
        let record = try DmToonParser.record(from: details.result, forGtin: gtin)

        // found=false is a clean not-found, not an error (the
        // orchestrator may cache it negatively).
        guard record["found"] == "true", let name = record["productName"], !name.isEmpty else {
            return nil
        }
        let imageURL = record["image"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return ResolvedProduct(
            gtin: record["gtin"].flatMap { $0.isEmpty ? nil : $0 } ?? gtin,
            name: name,
            brand: record["brand"] ?? "",
            imageURL: imageURL,
            source: .mcp
        )
    }

    // MARK: - Transport helpers

    private func load(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        do {
            return try await loader.load(request)
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.network(reason: "catalog transport failed: \(error)")
        }
    }

    /// The dm server answers POST requests with a Server-Sent Events
    /// body whose single `data:` line carries the JSON-RPC envelope
    /// (research doc section 4.4). A one-shot client only needs that
    /// line.
    private static func sseJSON(from data: Data) throws -> Data {
        guard let body = String(data: data, encoding: .utf8) else {
            throw CatalogError.parse(reason: "dm MCP response is not valid UTF-8")
        }
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !jsonText.isEmpty {
                return Data(jsonText.utf8)
            }
        }
        throw CatalogError.parse(reason: "no data: line in the dm MCP SSE response")
    }

    private func baseRequest(
        body: some Encodable,
        timeout: TimeInterval,
        sessionID: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(
                negotiatedProtocolVersion ?? requestedProtocolVersion,
                forHTTPHeaderField: "MCP-Protocol-Version"
            )
        }
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func nextRequestID() -> Int {
        defer { requestID += 1 }
        return requestID
    }
}

// MARK: - JSON-RPC payloads (file-private; see the recorded fixtures

// in PrivateInventoryTests/Fixtures for the wire format)

/// `initialize` request.
private struct DmMcpInitializeRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method = "initialize"
    let params: DmMcpInitializeParams
}

private struct DmMcpInitializeParams: Encodable {
    let protocolVersion: String
    let capabilities = DmMcpEmptyObject()
    let clientInfo = DmMcpClientInfo()
}

private struct DmMcpClientInfo: Encodable {
    let name = "private-inventory"
    let version = "1.0"
}

/// Encodes as `{}` (the MCP handshake sends no capabilities).
private struct DmMcpEmptyObject: Encodable {}

/// `notifications/initialized` notification (no `id`).
private struct DmMcpInitializedNotification: Encodable {
    let jsonrpc = "2.0"
    let method = "notifications/initialized"
}

/// `tools/call getProductDetails` request.
private struct DmMcpToolCallRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method = "tools/call"
    let params: DmMcpToolCallParams
}

private struct DmMcpToolCallParams: Encodable {
    let name = "getProductDetails"
    let arguments: DmMcpToolCallArguments
}

private struct DmMcpToolCallArguments: Encodable {
    /// The GTIN as Int64 on purpose: the server's JSON schema
    /// rejects strings (research doc section 4.1).
    let gtins: [Int64]
}

/// The JSON-RPC error object (HTTP 400/404 bodies and error results).
private struct DmMcpJsonRpcError: Decodable {
    let code: Int
    let message: String
}

/// `initialize` response envelope.
private struct DmMcpInitializeEnvelope: Decodable {
    let error: DmMcpJsonRpcError?
    let result: DmMcpInitializeResult?
}

private struct DmMcpInitializeResult: Decodable {
    let protocolVersion: String?
}

/// `tools/call` response envelope.
private struct DmMcpToolCallEnvelope: Decodable {
    let error: DmMcpJsonRpcError?
    let result: DmMcpToolCallResult?
}

private struct DmMcpToolCallResult: Decodable {
    let content: [DmMcpContentItem]?
    let isError: Bool?
}

private struct DmMcpContentItem: Decodable {
    let type: String?
    let text: String?
}

/// The inner JSON object of the tool result text:
/// `{"instruction": "...", "result": "<TOON table>"}`.
private struct DmMcpProductDetailsPayload: Decodable {
    let result: String
}
