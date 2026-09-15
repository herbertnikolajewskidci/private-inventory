import Foundation

/// Catalog source for OpenBeautyFacts (OBF) and OpenFoodFacts (OFF),
/// the open product databases for non-dm products (ADR-0002, last in
/// the lookup chain).
///
/// Both run the same Product Opener software with the same API:
/// `GET /api/v2/product/{barcode}.json`. The client asks OBF first
/// and falls back to OFF when OBF does not know the product. A
/// *network error* of OBF is not a miss: it is rethrown, so the
/// orchestrator (not this client) decides about fallbacks and a
/// rate-limited "1 call = 1 real scan" call is never burned on a
/// degraded source. The usage rule itself is enforced by the catalog
/// cache (ticket #14), not by this client.
struct OBFOffCatalogSource: CatalogSource {
    private let loader: any URLLoading
    private static let openBeautyFactsBase = URL(string: "https://world.openbeautyfacts.org")!
    private static let openFoodFactsBase = URL(string: "https://world.openfoodfacts.org")!

    /// OBF/OFF require a descriptive custom User-Agent (their API
    /// policy).
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
        if let product = try await lookup(base: Self.openBeautyFactsBase, gtin: gtin) {
            return product
        }
        return try await lookup(base: Self.openFoodFactsBase, gtin: gtin)
    }

    /// One database lookup. Returns `nil` for a clean miss (HTTP 404
    /// with `status:0`, or `status:0` on any status); throws a
    /// `CatalogError` for transport and parse failures.
    private func lookup(base: URL, gtin: String) async throws -> ResolvedProduct? {
        var request = URLRequest(url: base.appendingPathComponent("api/v2/product/\(gtin).json"))
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader.load(request)
        // A miss is HTTP 404 with body {"status":0,...}; both the 200
        // and the 404 are answers, not errors.
        guard response.statusCode == 200 || response.statusCode == 404 else {
            throw CatalogError.network(reason: "\(base.host ?? "unknown host") answered HTTP \(response.statusCode)")
        }
        let payload = try decodeCatalogJSON(OpenFactsResponse.self, from: data)
        guard payload.status == 1, let product = payload.product else {
            return nil
        }
        guard let name = product.productName, !name.isEmpty else {
            // Found but no usable name: no storable data.
            return nil
        }
        return ResolvedProduct(
            gtin: gtin,
            name: name,
            brand: product.firstBrand ?? "",
            imageURL: product.imageFrontURL.flatMap { URL(string: $0) },
            source: .obf
        )
    }
}

// MARK: - Response format (see the recorded fixtures)

private struct OpenFactsResponse: Decodable {
    /// 1 = product found, 0 = product not found (HTTP 404).
    let status: Int
    let product: OpenFactsProduct?
}

private struct OpenFactsProduct: Decodable {
    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case imageFrontURL = "image_front_url"
    }

    let code: String?
    let productName: String?
    /// Comma-separated brand list ("Nutella, Ferrero").
    let brands: String?
    let imageFrontURL: String?

    /// The first entry of the comma-separated `brands` list.
    var firstBrand: String? {
        brands?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
