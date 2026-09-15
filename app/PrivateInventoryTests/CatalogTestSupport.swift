import Foundation
@testable import PrivateInventory
import Testing

// Test support for the catalog clients (ADR-0006): recorded fixtures
// from the test bundle and a hand-written URL stub that replays them
// in request order. No test touches the network.

/// Loads recorded fixtures from `Fixtures/` in the test bundle.
enum Fixture {
    /// Anchor class: the tests are structs, so `Bundle(for:)` needs a
    /// class to locate the test bundle.
    final class Anchor {}

    static let bundle = Bundle(for: Anchor.self)

    /// The raw bytes of a recorded fixture file.
    static func data(_ name: String) -> Data {
        let resource = (name as NSString).deletingPathExtension
        let extensionName = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: resource, withExtension: extensionName),
              let data = try? Data(contentsOf: url)
        else {
            fatalError("fixture '\(name)' not found in the test bundle (Fixtures/)")
        }
        return data
    }

    /// The text of a recorded fixture file.
    static func string(_ name: String) -> String {
        String(data: data(name), encoding: .utf8) ?? ""
    }

    /// One header value out of a recorded `<name>.headers.txt` file
    /// (the raw dump `curl -D` writes; names are lower-case).
    static func header(_ name: String, from file: String) -> String? {
        // Newline graphemes, not "\n": the recorded files use CRLF,
        // which Swift treats as ONE character — a plain "\n" split
        // would leave the whole file as a single "line".
        for line in string(file).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("\(name.lowercased()):") else { continue }
            return String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// A `URLLoading` stub (ADR-0006: hand-written, no URLProtocol
/// interception): replays recorded responses in request order and
/// records every request the client sends (method, URL, headers,
/// body) so tests can assert on the wire format.
actor StubURLLoading: URLLoading {
    /// One recorded HTTP response.
    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data

        /// A response whose body is a recorded fixture file.
        init(statusCode: Int, fixture: String, headers: [String: String] = [:]) {
            self.init(statusCode: statusCode, bodyData: Fixture.data(fixture), headers: headers)
        }

        /// A response with an inline body (synthetic cases).
        init(statusCode: Int, body: String, headers: [String: String] = [:]) {
            self.init(statusCode: statusCode, bodyData: Data(body.utf8), headers: headers)
        }

        private init(statusCode: Int, bodyData: Data, headers: [String: String]) {
            self.statusCode = statusCode
            self.headers = headers
            body = bodyData
        }
    }

    /// One request as the client sent it.
    struct Request: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: String?
    }

    private var responses: [Response]
    private var requests: [Request] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func load(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        requests.append(
            Request(
                method: request.httpMethod ?? "",
                url: request.url?.absoluteString ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            )
        )
        guard !responses.isEmpty else {
            fatalError(
                "StubURLLoading: the client sent more requests than the stub has recorded responses"
            )
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.statusCode, httpVersion: "HTTP/2",
            headerFields: next.headers
        )!
        return (next.body, response)
    }

    /// The requests the client sent, in order.
    func recordedRequests() -> [Request] {
        requests
    }
}

/// A `URLLoading` stub that throws a custom error, testing that
/// catalog clients normalize foreign transport errors into
/// `CatalogError.network`.
struct FailingURLLoading: URLLoading {
    struct CustomTransportError: Error, Equatable {}

    let error: any Error

    init(error: any Error = CustomTransportError()) {
        self.error = error
    }

    func load(_: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        throw error
    }
}
