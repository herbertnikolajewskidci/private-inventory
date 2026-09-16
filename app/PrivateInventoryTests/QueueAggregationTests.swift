import Foundation
@testable import PrivateInventory
import Testing

@Suite("aggregateUnresolvedScans: display-only queue aggregation (GTIN, location)")
struct QueueAggregationTests {
    private let keller = Location(id: UUID(), name: "Keller")
    private let vorratsschrank = Location(id: UUID(), name: "Vorratsschrank")

    private func makeScan(
        gtin: String,
        location: Location,
        createdAt: Date
    ) throws -> UnresolvedScan {
        try UnresolvedScan(gtin: gtin, locationID: location.id, quantity: 1, createdAt: createdAt)
    }

    @Test("three scans of the same GTIN at the same location aggregate into one row with count 3")
    func sameGtinSameLocationAggregatesToCountThree() throws {
        // Given: 3 queued scans, same GTIN, same location
        let scans = try [
            makeScan(gtin: "4012345678901", location: keller, createdAt: date(1)),
            makeScan(gtin: "4012345678901", location: keller, createdAt: date(2)),
            makeScan(gtin: "4012345678901", location: keller, createdAt: date(3))
        ]

        // When: the scans are aggregated
        let rows = aggregateUnresolvedScans(scans, locations: [keller, vorratsschrank])

        // Then: exactly one row, count 3, newest timestamp, named location
        #expect(rows.count == 1)
        #expect(rows[0].gtin == "4012345678901")
        #expect(rows[0].locationID == keller.id)
        #expect(rows[0].locationName == "Keller")
        #expect(rows[0].count == 3)
        #expect(rows[0].lastScannedAt == date(3))
    }

    @Test("the same GTIN at two locations produces two rows")
    func sameGtinTwoLocationsProducesTwoRows() throws {
        // Given: one scan of the same GTIN at each location
        let scans = try [
            makeScan(gtin: "4012345678901", location: keller, createdAt: date(1)),
            makeScan(gtin: "4012345678901", location: vorratsschrank, createdAt: date(2))
        ]

        // When: the scans are aggregated
        let rows = aggregateUnresolvedScans(scans, locations: [keller, vorratsschrank])

        // Then: two rows, one per location, each with count 1
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.locationID)) == Set([keller.id, vorratsschrank.id]))
        #expect(rows.allSatisfy { $0.count == 1 })
    }

    @Test("different GTINs at the same location produce separate rows")
    func differentGtinsSameLocationProduceSeparateRows() throws {
        // Given: two scans with different (valid) GTINs at one location
        let scans = try [
            makeScan(gtin: "4012345678901", location: keller, createdAt: date(1)),
            makeScan(gtin: "4000000000006", location: keller, createdAt: date(2))
        ]

        // When: the scans are aggregated
        let rows = aggregateUnresolvedScans(scans, locations: [keller, vorratsschrank])

        // Then: two rows, one per GTIN
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.gtin)) == Set(["4012345678901", "4000000000006"]))
    }

    @Test("rows are sorted newest first with deterministic gtin tie-break")
    func sortedNewestFirstWithGtinTieBreak() throws {
        // Given: group "...0006" is oldest; groups "...0013" and "...0020"
        // share the newest timestamp (tie-break: gtin ascending)
        let scans = try [
            makeScan(gtin: "4000000000006", location: keller, createdAt: date(1)),
            makeScan(gtin: "4000000000013", location: keller, createdAt: date(5)),
            makeScan(gtin: "4000000000020", location: keller, createdAt: date(5))
        ]

        // When: the scans are aggregated
        let rows = aggregateUnresolvedScans(scans, locations: [keller, vorratsschrank])

        // Then: newest group first, then gtin ascending for equal timestamps
        #expect(rows.map(\.gtin) == ["4000000000013", "4000000000020", "4000000000006"])
    }

    @Test("an unknown location id falls back to the localized fallback name")
    func unknownLocationFallsBackToFallbackName() throws {
        // Given: a scan whose location is not in the known locations
        let unknown = Location(id: UUID(), name: "Nirgendwo")
        let scans = try [
            makeScan(gtin: "4012345678901", location: unknown, createdAt: date(1))
        ]

        // When: the scans are aggregated without the unknown location
        let rows = aggregateUnresolvedScans(scans, locations: [keller, vorratsschrank])

        // Then: the row uses the fallback name
        #expect(rows.count == 1)
        #expect(rows[0].locationID == unknown.id)
        #expect(rows[0].locationName == "Unbekannt")
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
