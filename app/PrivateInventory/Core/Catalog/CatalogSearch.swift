import Foundation

/// A source that finds products by free text (photo recognition,
/// ticket #24): OCR label text → catalog candidates. Lives next to
/// `CatalogSource` in `Core/Catalog/` (Foundation only, ADR-0007).
///
/// Candidates carry their OWN gtin (they are not the queried text).
/// The photo flow binds the scanned GTIN to the confirmed
/// candidate as an alias (ADR-0009); the candidates themselves are
/// NOT cached (curated truth lives in the inventory, D7a).
protocol CatalogSearch: Sendable {
    /// Free-text product search. Empty/whitespace-only queries
    /// return `[]` without a network call. Throws `CatalogError`
    /// (same semantics as `CatalogSource.resolve`).
    func search(query: String) async throws -> [ResolvedProduct]
}
