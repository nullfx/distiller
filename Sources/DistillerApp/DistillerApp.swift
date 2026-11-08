import AppKit
import SwiftUI

@main
struct DistillerApp: App {
    @State private var model = AppModel()

    init() {
        // `swift run DistillerApp` starts as a background process with no Dock icon or menu bar.
        // Making it a regular app fixes that; a bundled .app doesn't need it but isn't harmed.
        NSApplication.shared.setActivationPolicy(.regular)
        Self.migratePreferences()
    }

    /// Development builds used the placeholder bundle identifier `com.example.distiller`.
    /// Bring their preferences (library layout, the remembered GitHub account, the setup
    /// assistant's state) across once, the first time this identifier runs.
    private static func migratePreferences() {
        let oldDomain = "com.example.distiller"
        let defaults = UserDefaults.standard
        guard let identifier = Bundle.main.bundleIdentifier, identifier != oldDomain,
              defaults.persistentDomain(forName: identifier)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            defaults.set(value, forKey: key)
        }
    }

    var body: some Scene {
        WindowGroup("Distiller") {
            ContentView()
                .environment(model)
                // Narrow enough to sit beside a game, wide enough that the toolbar and each
                // game's details fit on a line; opens at 920 × 580.
                .frame(minWidth: 620, minHeight: 340)
                .task { await model.start() }
                .onAppear { NSApp.activate() }
                // distiller:// links from the catalogue website; keep them in this window
                // rather than opening a new one per link.
                .onOpenURL { model.open($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 920, height: 580)
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

        Window("Connect an AI Assistant", id: AssistantConnectView.windowID) {
            AssistantConnectView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentMinSize)
    }
}
