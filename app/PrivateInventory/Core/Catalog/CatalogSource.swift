import Foundation

/// Product data resolved from a catalog source.
///
/// The fields match the `Product` data (ADR-0003) the lookup chain
/// (ticket #14) will store in the catalog cache: name, brand, image
/// URL and the source the data came from.
struct ResolvedProduct: Equatable, Sendable {
    /// The GTIN the source resolved.
    let gtin: String
    var name: String
    var brand: String
    var imageURL: URL?
    /// Where the product data came from.
    let source: ProductSource
    /// How long the source said the data stays fresh, in seconds.
    /// Read from the HTTP `cache-control` header of the response:
    /// the dm search API answers `max-age=345600` (4 days), the other
    /// sources give no hint (`nil`). The catalog cache (ticket #14)
    /// uses the value to expire entries.
    var cacheTTL: TimeInterval?

    init(
        gtin: String,
        name: String,
        brand: String,
        imageURL: URL?,
        source: ProductSource,
        cacheTTL: TimeInterval? = nil
    ) {
        self.gtin = gtin
        self.name = name
        self.brand = brand
        self.imageURL = imageURL
        self.source = source
        self.cacheTTL = cacheTTL
    }
}

/// Errors a catalog source can throw.
///
/// The cases are the decision points of the lookup orchestrator
/// (ticket #14). A not-found is *not* an error: `resolve(gtin:)`
/// returns `nil` for it, so the orchestrator can record a negative
/// cache entry and continue the fallback chain. A thrown error means
/// the source is unusable for this request — fall back, never cache
/// a negative.
enum CatalogError: Error, Equatable, Sendable {
    /// The GTIN is not a barcode number this source can query with
    /// (e.g. non-numeric).
    case invalidGtin(gtin: String)
    /// The request could not be completed: transport failure (no
    /// connection, timeout), an HTTP error status, or a JSON-RPC
    /// error from the server.
    case network(reason: String)
    /// The response arrived but could not be parsed into product
    /// data (malformed JSON, unexpected structure, missing fields).
    case parse(reason: String)
}

/// A source that resolves a GTIN to product data.
///
/// The implementations are the network adapters of ADR-0002 (dm MCP,
/// dm search API, OpenBeautyFacts/OpenFoodFacts). The protocol lives
/// in `Core/Catalog/` and stays free of framework imports except
/// Foundation (ADR-0007 layer rule), so the lookup chain can
/// orchestrate the sources without knowing the transport.
///
/// Outcome model (the contract the orchestrator of ticket #14 builds
/// on):
/// - resolved product → return the `ResolvedProduct`
/// - clean not-found (the source has no data for this GTIN) → return
///   `nil`, do not throw
/// - failed request → throw a `CatalogError`
///
/// A source that *finds* a product but returns no usable name
/// (required for a `Product`) also returns `nil`: there is no
/// storable data, and treating it as a miss keeps repeat scans from
/// re-hitting rate-limited APIs.
protocol CatalogSource: Sendable {
    /// Resolves a GTIN to product data.
    ///
    /// - Parameter gtin: the barcode number as scanned (digits).
    /// - Returns: the resolved product data, or `nil` when this
    ///   source has no usable data for the GTIN (a clean not-found).
    /// - Throws: `CatalogError.invalidGtin` for GTINs the source
    ///   cannot query with, `CatalogError.network` when the request
    ///   could not be completed, `CatalogError.parse` when the
    ///   response could not be decoded.
    func resolve(gtin: String) async throws -> ResolvedProduct?
}

/// Decodes a catalog response, mapping every decoding failure to
/// `CatalogError.parse` (shared by all catalog clients).
func decodeCatalogJSON<T: Decodable>(_: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw CatalogError.parse(reason: "invalid \(T.self) payload: \(error)")
    }
}
