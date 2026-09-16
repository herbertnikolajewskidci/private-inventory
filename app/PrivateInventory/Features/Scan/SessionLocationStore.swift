import Foundation

/// "Last used" session-location preference (ADR-0008: App/Feature layer,
/// never GRDB). Stores the UUID as a string in UserDefaults.
struct SessionLocationStore: @unchecked Sendable {
    static let preferenceKey = "sessionLocationID"

    /// UserDefaults is a thread-safe class (Apple-documented); the store
    /// is immutable after init, so `@unchecked Sendable` is safe.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> UUID? {
        guard let raw = defaults.string(forKey: Self.preferenceKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// `nil` clears the preference.
    func write(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.preferenceKey)
        } else {
            defaults.removeObject(forKey: Self.preferenceKey)
        }
    }
}
