import Foundation
import Network
import SwiftUI

/// Production dependencies, built once and kept alive for the app
/// lifetime (App layer wiring, ADR-0007).
@MainActor
struct AppEnvironment {
    let database: InventoryDatabase
    let repository: any InventoryRepository
    let lookup: CatalogLookup
    let locationStore: SessionLocationStore
    let scanner: any Scanner
    /// Trigger ② monitor; stays alive on the environment.
    let pathMonitor: NWPathMonitor

    init() throws {
        let database = try InventoryDatabase(path: Self.databasePath())
        let repository = GRDBInventoryRepository(database: database)
        let cache = GRDBCatalogCache(database: database)
        let lookup = CatalogLookup(
            cache: cache,
            sources: [
                DmMcpCatalogSource(),
                DmSearchCatalogSource(),
                OBFOffCatalogSource()
            ],
            repository: repository
        )
        self.database = database
        self.repository = repository
        self.lookup = lookup
        locationStore = SessionLocationStore()
        #if targetEnvironment(simulator)
            scanner = ScannerStub()
        #else
            scanner = VisionKitScanner()
        #endif
        pathMonitor = NWPathMonitor()
    }

    /// Application Support directory (created if missing).
    static func databasePath() throws -> String {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory not available"]
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("PrivateInventory.sqlite").path
    }

    /// Trigger ②: on every network-path transition to `.satisfied`,
    /// re-resolve pending (queued) scans — fire-and-forget, idempotent
    /// (same style as Trigger ① in the core). Runs until the caller's
    /// task is cancelled (view disappear), which cancels the monitor.
    @MainActor
    func runQueueReResolution() async {
        var wasSatisfied = false
        do {
            for try await path in pathMonitor.pathUpdates() {
                let isSatisfied = path.status == .satisfied
                if isSatisfied, !wasSatisfied {
                    await runQueueOnce()
                }
                wasSatisfied = isSatisfied
            }
        } catch {
            // Monitor cancelled or failed: nothing to do (idempotent).
        }
    }

    /// One resolution run with bounded backoff retries (CodeRabbit: a
    /// single failed run must not park the queue until the NEXT path
    /// transition — the network may stay up afterwards). Cancellation
    /// stops the loop; an exhausted retry stays observable through the
    /// next trigger (path transition or Trigger ① of the next scan).
    @MainActor
    private func runQueueOnce() async {
        let maxAttempts = 3
        for attempt in 0 ..< maxAttempts {
            if Task.isCancelled {
                return
            }
            do {
                let resolved = try await lookup.resolvePendingScans()
                if resolved > 0 {
                    // Queue rows were booked/removed: refresh any open
                    // queue view (CodeRabbit: the aggregation would
                    // otherwise show removed scans until tab re-entry).
                    NotificationCenter.default.post(name: .queueDidChange, object: nil)
                }
                return
            } catch {
                guard attempt < maxAttempts - 1 else { return }
                try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
    }
}

/// Posted by the App-layer queue run after scans were booked/removed
/// (the queue tab is read-only and observes this instead of polling).
extension Notification.Name {
    static let queueDidChange = Notification.Name("queueDidChange")
}

extension NWPathMonitor {
    /// Async sequence of network path updates; the monitor is started
    /// eagerly and cancelled when the sequence terminates.
    func pathUpdates() -> AsyncThrowingStream<NWPath, Error> {
        AsyncThrowingStream { continuation in
            let monitor = self
            continuation.yield(monitor.currentPath)
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            monitor.start(queue: .main)
            continuation.onTermination = { _ in
                monitor.cancel()
            }
        }
    }
}

/// Root view: builds the `AppEnvironment` (ProgressView until ready)
/// and hosts the 4-anchor tab bar (D1a).
@MainActor
struct AppRootView: View {
    @State private var environment: Result<AppEnvironment, Error>?

    var body: some View {
        Group {
            switch environment {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .some(.failure(error)):
                VStack(spacing: 12) {
                    Text("Datenbank konnte nicht geöffnet werden")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            case let .some(.success(environment)):
                MainTabView(environment: environment)
            }
        }
        .task {
            guard environment == nil else { return }
            do {
                environment = try .success(AppEnvironment())
            } catch {
                environment = .failure(error)
            }
            if case let .success(environment) = environment {
                await environment.runQueueReResolution()
            }
        }
    }
}

/// 4-anchor tab bar (D1a): Home, Standorte, Scan, Queue.
private struct MainTabView: View {
    let environment: AppEnvironment
    @State private var selection: Tab = .home

    enum Tab: Hashable {
        case home
        case locations
        case scan
        case queue
    }

    var body: some View {
        TabView(selection: $selection) {
            PlaceholderTabView(title: "Bestand")
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Tab.home)

            PlaceholderTabView(title: "Standorte")
                .tabItem {
                    Label("Standorte", systemImage: "mappin.and.ellipse")
                }
                .tag(Tab.locations)

            ScanTabView(
                repository: environment.repository,
                lookup: environment.lookup,
                store: environment.locationStore,
                scanner: environment.scanner
            )
            .tabItem {
                Label("Scan", systemImage: "barcode.viewfinder")
            }
            .tag(Tab.scan)

            QueueTabView(repository: environment.repository)
                .tabItem {
                    Label("Queue", systemImage: "tray.2")
                }
                .tag(Tab.queue)
        }
    }
}

/// Clearly-labeled placeholder screen; the real screens come with a
/// later ticket (D1a).
private struct PlaceholderTabView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title.bold())
            Text("Kommt mit einem späteren Ticket.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct PrivateInventoryApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
