import SwiftUI

@main
struct ReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Reel", id: "main") {
            StreamInspectorView(model: AppModel.shared)
                .frame(minWidth: 560, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { AppModel.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
