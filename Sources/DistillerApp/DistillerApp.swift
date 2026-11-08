import AppKit
import SwiftUI

@main
struct DistillerApp: App {
    @State private var model = AppModel()

    init() {
        // `swift run DistillerApp` starts as a background process with no Dock icon or menu bar.
        // Making it a regular app fixes that; a bundled .app doesn't need it but isn't harmed.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Distiller") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 580)
                .task { await model.start() }
                .onAppear { NSApp.activate() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Create Recipe…") { model.isCreatingRecipe = true }
                    .keyboardShortcut("n")
                Button("Add Game from Recipe File…") { model.isImportingRecipe = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .appSettings) {
                Button("Setup Assistant…") { model.isShowingSetup = true }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
