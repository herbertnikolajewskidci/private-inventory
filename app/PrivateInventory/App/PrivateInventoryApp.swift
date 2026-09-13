import SwiftUI

@main
struct PrivateInventoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Inventar")
    }
}

#Preview {
    ContentView()
}
