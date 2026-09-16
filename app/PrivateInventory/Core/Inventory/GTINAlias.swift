import Foundation

/// An additional GTIN that maps to an existing Product (ADR-0009):
/// the old packaging of a relisted product scans as a different
/// barcode, but books at the SAME product (no duplicate). The
/// product's own GTIN stays its primary identity.
struct GTINAlias: Identifiable, Equatable, Codable {
    /// Sync-capable identity: a UUID stored as text (ADR-0005).
    let id: UUID
    /// The alias GTIN (e.g. the delisted barcode as scanned).
    let gtin: String
    /// The product this alias resolves to.
    let productID: UUID

    init(id: UUID = UUID(), gtin: String, productID: UUID) {
        self.id = id
        self.gtin = gtin
        self.productID = productID
    }
}
