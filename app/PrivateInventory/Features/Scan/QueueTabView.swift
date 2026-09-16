import SwiftUI

/// Queue tab (D2a): read-only list of unresolved scans aggregated by
/// (GTIN, location), shown as "3×". Actions come with a later ticket.
struct QueueTabView: View {
    private let repository: any InventoryRepository
    @State private var rows: [AggregatedQueueRow] = []

    init(repository: any InventoryRepository) {
        self.repository = repository
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    Text("Keine ungelösten Scans")
                        .foregroundStyle(.secondary)
                } else {
                    List(rows) { row in
                        QueueRowView(row: row)
                    }
                }
            }
            .navigationTitle("Ungelöste Scans")
            // Refresh on every tab appear.
            .task {
                load()
            }
        }
    }

    private func load() {
        do {
            let scans = try repository.fetchUnresolvedScans()
            let locations = try repository.fetchLocations()
            rows = aggregateUnresolvedScans(scans, locations: locations)
        } catch {
            rows = []
        }
    }
}

private struct QueueRowView: View {
    let row: AggregatedQueueRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.gtin)
                    .font(.headline)
                    .monospaced()
                Text(row.locationName)
                Text(row.lastScannedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(row.count)×")
                .font(.title3.bold())
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    if let database = try? InventoryDatabase.makeInMemory() {
        QueueTabView(repository: GRDBInventoryRepository(database: database))
    }
}
