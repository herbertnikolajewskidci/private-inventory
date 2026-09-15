import Foundation

/// Catalog source for the unofficial dm search API (ADR-0002, second
/// in the lookup chain).
///
/// Queries the dm.de shop backend (`product-search.services.dmtech.com`)
/// with the GTIN as search term. The response is a plain JSON product
/// list; a GTIN query can also return *other* products, so a hit is
/// only a product whose own `gtin` field matches.
///
/// The server marks the results as cacheable for 4 days
/// (`cache-control: public, max-age=345600`, recorded in the
/// fixture headers). The client respects the header by forwarding
/// its `max-age` in `ResolvedProduct.cacheTTL`; the catalog cache
/// (ticket #14) applies it.
struct DmSearchCatalogSource: CatalogSource {
    private let loader: any URLLoading

    /// A descriptive User-Agent identifies the app to the backend.
    private static let userAgent =
        "private-inventory/1.0 (personal household inventory app; "
            + "github.com/herbertnikolajewskidci/private-inventory)"

    init(loader: any URLLoading = URLSessionURLLoading()) {
        self.loader = loader
    }

    func resolve(gtin: String) async throws -> ResolvedProduct? {
        guard gtin.allSatisfy(\.isNumber) else {
            throw CatalogError.invalidGtin(gtin: gtin)
        }
        let request = Self.makeRequest(gtin: gtin)
        let (data, response) = try await loader.load(request)
        guard response.statusCode == 200 else {
            throw CatalogError.network(reason: "dm search answered HTTP \(response.statusCode)")
        }
        let search = try decodeCatalogJSON(DmSearchResponse.self, from: data)
        guard let product = search.products.first(where: { $0.gtin?.value == gtin }) else {
            // Empty list or other products: clean not-found.
            return nil
        }
        guard let name = product.title, !name.isEmpty else {
            // Found but no usable name: no storable data.
            return nil
        }
        return ResolvedProduct(
            gtin: gtin,
            name: name,
            brand: product.brandName ?? "",
            imageURL: product.tileData?.images?.first?.tileSrc.flatMap { URL(string: $0) },
            source: .search,
            cacheTTL: Self.cacheTTL(from: response)
        )
    }

    // MARK: - Request

    /// The crawl endpoint with the GTIN as query term (the dead
    /// direct-GTIN endpoints under `products.dm.de` are history, see
    /// research doc section 1.2).
    static func makeRequest(gtin: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "product-search.services.dmtech.com"
        components.path = "/de/search/crawl"
        components.queryItems = [
            URLQueryItem(name: "query", value: gtin),
            URLQueryItem(name: "pageSize", value: "5"),
            URLQueryItem(name: "currentPage", value: "0"),
            URLQueryItem(name: "type", value: "search-static")
        ]
        var request = URLRequest(url: components.url ?? URL(string: "https://product-search.services.dmtech.com")!)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Reads the `max-age` directive of the `cache-control` response
    /// header (the dm search API answers a 4-day max-age); `nil` when
    /// the server gives no cache hint.
    static func cacheTTL(from response: HTTPURLResponse) -> TimeInterval? {
        guard let cacheControl = response.headerValue("cache-control") else { return nil }
        for directive in cacheControl.split(separator: ",") {
            let parts = directive.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.first?.lowercased() == "max-age",
                  let seconds = parts.dropFirst().first.flatMap(TimeInterval.init)
            else {
                continue
            }
            return seconds
        }
        return nil
    }
}

// MARK: - Response format (see the recorded fixtures)

private struct DmSearchResponse: Decodable {
    let products: [DmSearchProduct]
}

private struct DmSearchProduct: Decodable {
    let gtin: DmSearchGTIN?
    let brandName: String?
    let title: String?
    let tileData: DmSearchTileData?
}

private struct DmSearchTileData: Decodable {
    let images: [DmSearchImage]?
}

private struct DmSearchImage: Decodable {
    let tileSrc: String?
}

/// The `gtin` field of a dm search product. The live response sends a
/// JSON number (Int64); a string is accepted as well, so a format
/// change does not silently break the GTIN match.
private struct DmSearchGTIN: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else if let string = try? container.decode(String.self) {
            value = string
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "gtin must be a number or a string"
            )
        }
    }
}
