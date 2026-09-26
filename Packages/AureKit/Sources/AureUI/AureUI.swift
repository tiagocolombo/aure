import SwiftUI

public enum AureMain {
    @MainActor public static func run() { AureApplication.main() }
}

struct AureApplication: App {
    var body: some Scene {
        MenuBarExtra("Aure", systemImage: "text.badge.checkmark") {
            Text("Aure").padding()
        }
        .menuBarExtraStyle(.window)
    }
}
