import SwiftUI

@main
struct MacordApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup {
            RecorderView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
