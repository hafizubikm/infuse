import SwiftUI

@main
struct ReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Reel", id: "library") {
            LibraryView(model: AppModel.shared)
                .frame(minWidth: 720, minHeight: 440)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { AppModel.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Add Folder to Library…") { LibraryStore.shared.presentAddFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
