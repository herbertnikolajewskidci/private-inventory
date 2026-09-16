import Foundation

/// Binds a scanned (unresolvable) GTIN to a product the user
/// confirmed — photo match (D3a/D4a) or manual form (D6a) — and
/// books ALL open queue rows for that GTIN (D5a). The confirm step
/// of the photo/manual resolution (ticket #24, ADR-0008 path 1,
/// ADR-0009).
struct ProductBinding {
    private let repository: any InventoryRepository

    init(repository: any InventoryRepository) {
        self.repository = repository
    }

    /// Number of open queue rows for a GTIN (D5a: the binding
    /// books ALL open rows of the scanned GTIN, not just one).
    func openRowCount(forGTIN gtin: String) throws -> Int {
        try repository.fetchUnresolvedScans().filter { $0.gtin == gtin }.count
    }

    /// Binds `scannedGTIN` (the GTIN the queue rows are queued
    /// under) to a product:
    /// - the product is reused when one already exists under
    ///   `productGTIN` (primary or alias; alias-aware
    ///   `fetchProduct`), otherwise created with the confirmed data
    ///   and `source = .manual` (D8a: the binding is the user's
    ///   curated truth).
    /// - when the bound product's own GTIN differs from
    ///   `scannedGTIN`, the scanned GTIN becomes an alias of the
    ///   product (ADR-0009) — both barcodes resolve to this product
    ///   from now on, permanently.
    /// - every open queue row of `scannedGTIN` is booked (per row
    ///   at its own location) and removed.
    ///
    /// - Throws: `InventoryError.duplicateGTIN` when the target GTIN
    ///   belongs to a different product (e.g. the user typed an
    ///   existing GTIN into the form) — the queue stays untouched;
    ///   `missingParent` when a queue row's location or the product
    ///   vanished mid-run.
    /// - Returns: the product the scanned GTIN now resolves to.
    func bind(
        scannedGTIN: String,
        productGTIN: String?,
        name: String,
        brand: String,
        imageURL: URL?
    ) throws -> Product {
        let targetGTIN = productGTIN ?? scannedGTIN
        let product: Product = if let existing = try repository.fetchProduct(gtin: targetGTIN) {
            existing
        } else {
            try repository.createProduct(
                Product(
                    gtin: targetGTIN,
                    name: name,
                    brand: brand,
                    imageURL: imageURL,
                    source: .manual
                )
            )
        }
        if product.gtin != scannedGTIN {
            try repository.createGTINAlias(
                gtin: scannedGTIN,
                productID: product.id
            )
        }
        let rows = try repository.fetchUnresolvedScans()
            .filter { $0.gtin == scannedGTIN }
        for row in rows {
            _ = try repository.bookUnresolvedScan(
                scanID: row.id,
                productID: product.id
            )
        }
        return product
    }
}
