import Foundation

/// The transport seam of the catalog clients (ADR-0006).
///
/// Production uses `URLSessionURLLoading`. Tests inject a
/// hand-written stub that replays recorded fixtures, so no test
/// touches the network and no `URLProtocol` interception is needed
/// (the rejected option of ADR-0006).
protocol URLLoading: Sendable {
    /// Performs the request and returns the body plus the HTTP
    /// response. The clients need the status code and the headers
    /// (e.g. the dm MCP `Mcp-Session-Id`, the dm search
    /// `cache-control`).
    func load(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

/// The production transport: plain `URLSession` (no frameworks).
struct URLSessionURLLoading: URLLoading {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogError.network(reason: "the response is not an HTTP response")
        }
        return (data, http)
    }
}

extension HTTPURLResponse {
    /// Case-insensitive lookup of a response header. HTTP/2 header
    /// names are lower-case, but `allHeaderFields` preserves them as
    /// sent, so a plain dictionary lookup would miss.
    func headerValue(_ name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard let key = key as? String, key.lowercased() == name.lowercased() else {
                continue
            }
            return value as? String
        }
        return nil
    }
}
