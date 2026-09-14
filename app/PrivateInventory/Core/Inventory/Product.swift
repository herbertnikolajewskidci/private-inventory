import Foundation

/// A physical product in the household.
///
/// Uniquely identified by its GTIN (the barcode number printed on
/// the packaging). The store enforces this with a unique constraint
/// on `gtin` (ADR-0003, ADR-0005).
struct Product: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text, never a local
    /// auto-increment key (ADR-0005).
    let id: UUID
    /// The barcode number printed on the packaging; the domain key
    /// of a Product.
    var gtin: String
    var name: String
    var brand: String
    var imageURL: URL?
    /// Where the product data came from.
    var source: ProductSource

    init(
        id: UUID = UUID(),
        gtin: String,
        name: String,
        brand: String,
        imageURL: URL? = nil,
        source: ProductSource
    ) {
        self.id = id
        self.gtin = gtin
        self.name = name
        self.brand = brand
        self.imageURL = imageURL
        self.source = source
    }
}

/// Where a Product's data came from.
enum ProductSource: String, Equatable, Codable {
    /// Resolved via the dm MCP server.
    case mcp
    /// Resolved via an external barcode search API.
    case search
    /// Resolved via an offline barcode format (OBF/OFF).
    case obf
    /// Entered or recorded manually.
    case manual
}
