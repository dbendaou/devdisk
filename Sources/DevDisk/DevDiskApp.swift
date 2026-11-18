#if os(macOS)
import SwiftUI

@main
struct DevDiskApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Home Folder") { model.scanHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(model.phase != .scanning)
            }
        }
    }
}
#endif
