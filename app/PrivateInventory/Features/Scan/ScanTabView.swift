import SwiftUI

/// Scan tab (D1a): session-location dropdown, camera area with the
/// permission flow, big Scan button, result overlay sheet.
struct ScanTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScanTabModel
    @State private var simulatedGtin = "4012345678901"

    init(
        repository: any InventoryRepository,
        lookup: CatalogLookup,
        store: SessionLocationStore,
        scanner: any Scanner
    ) {
        _model = State(
            initialValue: ScanTabModel(
                repository: repository,
                lookup: lookup,
                store: store,
                scanner: scanner
            )
        )
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .noLocations:
                Text("Kein Standort vorhanden")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            case let .loadFailed(message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .ready:
                locationSection
                cameraArea
                scanButton
                footer
                Spacer(minLength: 0)
            }
        }
        .padding()
        .sheet(item: $model.overlay) { overlay in
            ScanOverlayView(overlay: overlay, model: model)
                .presentationDetents([.fraction(0.55)])
                .presentationDragIndicator(.visible)
        }
        .task {
            model.start()
        }
        // Coming back from Settings must not leave a stale permission
        // state (otherwise the flow dead-ends in "denied").
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshPermissionState()
            }
        }
        // Tab switch: end an open scan window — recognition must not
        // continue invisibly in the background.
        .onDisappear {
            model.stopScanWindow()
        }
    }

    // MARK: Sections

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sitzungs-Standort")
                .font(.headline)
            Picker(
                "Sitzungs-Standort",
                selection: Binding(
                    get: { model.sessionLocation?.id },
                    set: { model.selectLocation($0) }
                )
            ) {
                ForEach(model.locations) { location in
                    Text(location.name)
                        .tag(Optional(location.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var cameraArea: some View {
        if model.isStubScanner {
            stubCameraArea
        } else if model.isScanning, let visionScanner = model.scanner as? VisionKitScanner {
            // Live camera preview during the scan window (device only).
            // A deferred startup failure is routed back to the model
            // (the window is not actually open then).
            ScannerHost(scanner: visionScanner) { failure in
                model.scanWindowFailed(failure)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            idleOrPermissionArea
        }
    }

    @ViewBuilder
    private var idleOrPermissionArea: some View {
        switch model.permissionState {
        case .notDetermined:
            permissionCard(
                titleKey: "Kamera-Berechtigung erforderlich",
                buttonKey: "Berechtigung anfordern"
            ) {
                Task {
                    await model.requestPermission()
                }
            }
        case .denied:
            permissionCard(
                titleKey: "Kamera-Zugriff deaktiviert",
                buttonKey: "In den Einstellungen aktivieren"
            ) {
                model.openSettings()
            }
        case .granted:
            if model.scannerIsAvailable {
                cameraPlaceholder("Kamera bereit")
                // Startup failure of the last window (cleared by the
                // next successful start).
                if let reason = model.unavailableReason {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            } else {
                cameraPlaceholder("Kamera nicht verfügbar")
            }
        }
    }

    #if targetEnvironment(simulator) && DEBUG
        // D4a: debug simulator build only, never in Release.
        private var stubCameraArea: some View {
            VStack(spacing: 12) {
                cameraPlaceholder("Kamera bereit")
                TextField("GTIN", text: $simulatedGtin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Scan simulieren") {
                    model.simulateScan(gtin: simulatedGtin)
                }
                .buttonStyle(.bordered)
            }
        }
    #else
        /// Device builds (and Release simulators) never run this branch:
        /// `isStubScanner` is false there.
        private var stubCameraArea: some View {
            cameraPlaceholder("Kamera bereit")
        }
    #endif

    private func permissionCard(
        titleKey: LocalizedStringKey,
        buttonKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Text(titleKey)
                .multilineTextAlignment(.center)
            Button(buttonKey, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func cameraPlaceholder(_ text: LocalizedStringKey) -> some View {
        VStack {
            Image(systemName: "barcode.viewfinder")
                .font(.largeTitle)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scanButton: some View {
        Button {
            model.startScan()
        } label: {
            Text("Scan")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            model.phase != .ready
                || model.isScanning
                || model.sessionLocation == nil
                || model.permissionState != .granted
                || !model.scannerIsAvailable
        )
    }

    @ViewBuilder
    private var footer: some View {
        if let locationName = model.sessionLocation?.name {
            Text("Bucht still ein: \(locationName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Result overlay card inside the sheet (D3a: "Wieder scannen +1" +
/// native swipe-down only — no "Details" button).
private struct ScanOverlayView: View {
    let overlay: ScanOverlay
    let model: ScanTabModel

    var body: some View {
        VStack(spacing: 16) {
            switch overlay.content {
            case let .booked(productName, gtin, sourceLabel, before, after, otherStock):
                Text("Einbuchen +1")
                    .font(.title2.bold())
                Text(productName)
                    .font(.headline)
                Text(gtin)
                    .font(.body.monospaced())
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Text("Bestand")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(before) → \(after)")
                        .font(.title3.bold())
                }
                if !otherStock.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(otherStock) { item in
                            Text("\(item.locationName): \(item.quantity)")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            case let .queued(gtin):
                Text(gtin)
                    .font(.body.monospaced())
                Text("Zählt als Bestand. Wird automatisch nachaufgelöst.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Scan konnte nicht verarbeitet werden.")
                    .foregroundStyle(.secondary)
            }
            Button("Wieder scannen +1") {
                model.rescan()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    if let database = try? InventoryDatabase.makeInMemory() {
        ScanTabView(
            repository: GRDBInventoryRepository(database: database),
            lookup: CatalogLookup(cache: GRDBCatalogCache(database: database), sources: []),
            store: SessionLocationStore(),
            scanner: ScannerStub()
        )
    }
}
