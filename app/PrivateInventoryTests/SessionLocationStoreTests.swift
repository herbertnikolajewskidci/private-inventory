import Foundation
@testable import PrivateInventory
import Testing

@Suite("SessionLocationStore: last-used session-location preference (UserDefaults)")
struct SessionLocationStoreTests {
    /// A dedicated, empty UserDefaults domain per test (unique name, so
    /// parallel test execution never shares state; no .standard).
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SessionLocationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "UserDefaults(suiteName:) must succeed")
        defaults?.removePersistentDomain(forName: suiteName)
        return defaults!
    }

    @Test("read returns nil when nothing is stored")
    func readReturnsNilWhenNothingStored() {
        // Given: a store backed by an empty dedicated domain
        let store = SessionLocationStore(defaults: makeDefaults())

        // When/Then: reading the preference yields nil
        #expect(store.read() == nil)
    }

    @Test("write then read roundtrips the session location id")
    func writeThenReadRoundtrips() {
        // Given: a store backed by an empty dedicated domain
        let store = SessionLocationStore(defaults: makeDefaults())
        let locationID = UUID()

        // When: the id is written
        store.write(locationID)

        // Then: reading returns the same id
        #expect(store.read() == locationID)
    }

    @Test("write nil clears the stored preference")
    func writeNilClearsPreference() {
        // Given: a store with a stored id
        let store = SessionLocationStore(defaults: makeDefaults())
        store.write(UUID())

        // When: nil is written
        store.write(nil)

        // Then: the preference is gone
        #expect(store.read() == nil)
    }
}
