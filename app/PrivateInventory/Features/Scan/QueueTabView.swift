import SwiftUI

/// The aggregated queue row a photo/manual resolution starts
/// from (D1a). Identified by the GTIN (D5a: the action binds
/// ALL open rows of the GTIN, not just one location).
struct QueueResolutionTarget: Identifiable, Equatable {
    let gtin: String
    let locationName: String

    var id: String {
        gtin
    }
}

/// Which resolution flow a tapped queue row starts (D1a).
enum ResolutionEntry: Equatable {
    case photo
    case manual
}

/// Queue tab (D2a): list of unresolved scans aggregated by (GTIN,
/// location), shown as "3×". Row actions (D1a) start the photo or
/// manual resolution (ticket #24).
struct QueueTabView: View {
    private let repository: any InventoryRepository
    private let catalogSearch: any CatalogSearch
    private let recognizer: any TextRecognizer
    @State private var rows: [AggregatedQueueRow] = []
    @State private var loadError: String?
    @State private var resolutionTarget: QueueResolutionTarget?
    @State private var entry: ResolutionEntry?

    init(
        repository: any InventoryRepository,
        catalogSearch: any CatalogSearch,
        recognizer: any TextRecognizer
    ) {
        self.repository = repository
        self.catalogSearch = catalogSearch
        self.recognizer = recognizer
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = loadError {
                    // Fetch failures must not masquerade as an empty
                    // queue (CodeRabbit): error state with retry.
                    VStack(spacing: 12) {
                        Text("Fehler beim Laden der Queue.")
                            .font(.headline)
                        Text(verbatim: error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Erneut versuchen") {
                            loadError = nil
                            load()
                        }
                        .buttonStyle(.bordered)
                    }
                } else if rows.isEmpty {
                    Text("Keine ungelösten Scans")
                        .foregroundStyle(.secondary)
                } else {
                    List(rows) { row in
                        QueueRowView(row: row)
                            .swipeActions(edge: .trailing) {
                                Button("Foto aufnehmen", systemImage: "camera.fill") {
                                    startResolution(.photo, for: row)
                                }
                                Button("Manuell anlegen", systemImage: "square.and.pencil") {
                                    startResolution(.manual, for: row)
                                }
                            }
                            .contextMenu {
                                Button("Foto aufnehmen", systemImage: "camera.fill") {
                                    startResolution(.photo, for: row)
                                }
                                Button("Manuell anlegen", systemImage: "square.and.pencil") {
                                    startResolution(.manual, for: row)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Ungelöste Scans")
            // Refresh on every tab appear.
            .task {
                load()
            }
            // Background resolution booked/removed scans while this
            // tab is open: refresh immediately instead of at next
            // re-entry (CodeRabbit).
            .onReceive(NotificationCenter.default.publisher(for: .queueDidChange)) { _ in
                load()
            }
            // One sheet for both resolution entries (D1a).
            .sheet(item: $resolutionTarget) { target in
                switch entry {
                case .photo:
                    PhotoRecognitionView(
                        scannedGTIN: target.gtin,
                        recognizer: recognizer,
                        search: catalogSearch,
                        binding: ProductBinding(repository: repository)
                    ) {
                        NotificationCenter.default.post(name: .queueDidChange, object: nil)
                    }
                case .manual:
                    ManualProductFormView(
                        scannedGTIN: target.gtin,
                        binding: ProductBinding(repository: repository)
                    ) {
                        NotificationCenter.default.post(name: .queueDidChange, object: nil)
                    }
                case nil:
                    EmptyView()
                }
            }
        }
    }

    private func startResolution(_ entry: ResolutionEntry, for row: AggregatedQueueRow) {
        self.entry = entry
        resolutionTarget = QueueResolutionTarget(gtin: row.gtin, locationName: row.locationName)
    }

    private func load() {
        do {
            let scans = try repository.fetchUnresolvedScans()
            let locations = try repository.fetchLocations()
            rows = aggregateUnresolvedScans(scans, locations: locations)
            loadError = nil
        } catch {
            // Keep the last rows visible; surface the failure with a
            // retry action instead of a fake empty queue.
            loadError = error.localizedDescription
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
        QueueTabView(
            repository: GRDBInventoryRepository(database: database),
            catalogSearch: DmSearchCatalogSource(),
            recognizer: TextRecognizerStub()
        )
    }
}
