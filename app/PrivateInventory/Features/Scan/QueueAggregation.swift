import Foundation

/// One row of the read-only queue tab: the number of queued scans for a
/// (GTIN, location) pair, shown as "3×" (ADR-0008: display-only).
struct AggregatedQueueRow: Equatable, Identifiable {
    let gtin: String
    let locationID: UUID
    let locationName: String
    let count: Int
    let lastScannedAt: Date
    var id: String {
        "\(gtin)-\(locationID.uuidString)"
    }
}

/// Groups unresolved scans by (GTIN, location): the row count is the
/// number of queued scans per group ("3×"; ADR-0008: aggregation is
/// display-only — queue rows stay separate). Newest group first
/// (lastScannedAt desc, tie-break gtin asc). Location names from
/// `locations`; unknown location id → localized fallback name.
func aggregateUnresolvedScans(_ scans: [UnresolvedScan], locations: [Location]) -> [AggregatedQueueRow] {
    let nameByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.name) })

    struct Group {
        let gtin: String
        let locationID: UUID
        var count = 0
        var lastScannedAt: Date
    }

    var groups: [String: Group] = [:]
    for scan in scans {
        let key = "\(scan.gtin)-\(scan.locationID.uuidString)"
        var group = groups[key] ?? Group(
            gtin: scan.gtin,
            locationID: scan.locationID,
            lastScannedAt: scan.createdAt
        )
        group.count += 1
        group.lastScannedAt = max(group.lastScannedAt, scan.createdAt)
        groups[key] = group
    }

    return groups
        .map { _, group in
            AggregatedQueueRow(
                gtin: group.gtin,
                locationID: group.locationID,
                locationName: nameByID[group.locationID] ?? "Unbekannt",
                count: group.count,
                lastScannedAt: group.lastScannedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastScannedAt != rhs.lastScannedAt {
                return lhs.lastScannedAt > rhs.lastScannedAt
            }
            return lhs.gtin < rhs.gtin
        }
}
