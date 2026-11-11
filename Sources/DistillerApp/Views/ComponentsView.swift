import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DistillerCore

struct ComponentsView: View {
    @Environment(AppModel.self) private var model

    /// One file importer serves both imports; SwiftUI only honours one per view.
    private enum ImportKind { case gptk, wine }
    @State private var importKind: ImportKind?
    @State private var isImporting = false
    @State private var pendingWineImport: PendingImport?

    var body: some View {
        List {
            if let hardware = model.hardware, !hardware.rosetta {
                Section {
                    Label {
                        Text("Rosetta isn't available, so x86_64 Wine builds won't run. Install it in Terminal with: softwareupdate --install-rosetta")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
            }

            ComponentUpdateNotices()

            ForEach(ComponentKind.allCases, id: \.self) { kind in
                Section(kind.displayName) {
                    let items = model.components.filter { $0.manifest.kind == kind }
                    if items.isEmpty {
                        Text(emptyText(for: kind)).foregroundStyle(.secondary)
                    }
                    ForEach(items) { component in
                        ComponentRow(component: component)
                    }
                }
            }
        }
        .navigationTitle("Components")
        .navigationSubtitle(updateStatus)
        .toolbar {
            Button {
                model.checkForComponentUpdates()
            } label: {
                if model.isCheckingForUpdates {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
            }
            .help("Check for newer Wine builds, graphics layers and winetricks")
            .disabled(model.isCheckingForUpdates || model.busyMessage != nil)
            Button {
                model.isShowingSetup = true
            } label: {
                Label("Setup Assistant", systemImage: "wand.and.stars")
            }
            .help("Check what's installed and install what's missing")
            Menu {
                Section("Download") {
                    ForEach(GraphicsLayerSource.all, id: \.id) { source in
                        let item = SetupItem(graphics: source.provides)
                        Button("Download \(source.displayName)") { if let item { model.install(item) } }
                            .disabled(model.busyMessage != nil)
                    }
                }
                Section("Import") {
                Button("Import D3DMetal from Game Porting Toolkit…") {
                    importKind = .gptk
                    isImporting = true
                }
                Button("Import Wine Build…") {
                    importKind = .wine
                    isImporting = true
                }
                }
            } label: {
                Label("Add Component", systemImage: "square.and.arrow.down")
            }
            .help("Download DXMT or DXVK, or import D3DMetal or a Wine build")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder, .diskImage, .archive]) { result in
            guard case .success(let url) = result else { return }
            switch importKind {
            case .gptk: model.importGPTK(from: url)
            case .wine: pendingWineImport = PendingImport(url: url)
            case nil: break
            }
        }
        .sheet(item: $pendingWineImport) { pending in
            ImportWineSheet(source: pending.url)
        }
    }

    /// Under the title: what the last check found, and when.
    private var updateStatus: String {
        if model.isCheckingForUpdates { return "Checking for updates…" }
        let count = model.componentUpdates.count
        if count > 0 { return count == 1 ? "1 update available" : "\(count) updates available" }
        guard let date = model.lastComponentCheck else { return "" }
        return "Up to date · checked \(date.formatted(.relative(presentation: .named)))"
    }

    private func emptyText(for kind: ComponentKind) -> String {
        switch kind {
        case .wine: return "Import a Wine build to create bottles."
        case .graphics: return "Download DXMT or DXVK from the Add Component menu, or import D3DMetal from Apple's Game Porting Toolkit."
        case .winetricks: return "Import the winetricks script to let recipes install runtime libraries."
        }
    }
}

struct ComponentRow: View {
    @Environment(AppModel.self) private var model
    let component: InstalledComponent

    /// An update for this component, shown on the row of its active version.
    private var update: ComponentUpdate? {
        guard model.activeComponentIDs.contains(component.id) else { return nil }
        return model.componentUpdates.first { $0.id == component.manifest.id }
    }

    /// Whether more than one version of this component is installed (only then does "active" mean anything).
    private var hasOtherVersions: Bool {
        model.components.contains { $0.manifest.id == component.manifest.id && $0.id != component.id }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.manifest.displayName)
                Text([component.manifest.version, component.manifest.arch.rawValue, component.manifest.family ?? component.manifest.provides?.displayName]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let update {
                Text("\(update.availableVersion) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(update.heldVersion.map { "You're keeping \($0) active, so automatic updates skip this one." } ?? "")
                Button("Update") { model.installComponentUpdate(update) }
                    .controlSize(.small)
                    .disabled(model.busyMessage != nil)
            } else if let games = model.keptForGames[component.id], !model.activeComponentIDs.contains(component.id) {
                Text("Kept for \(games.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("These games stay on this version (their Bottle settings in the workshop), so it isn't removed.")
            } else if hasOtherVersions {
                if model.activeComponentIDs.contains(component.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("Active: new games use this version, and games that follow updates move to it.")
                } else if model.unusedComponents.contains(component) {
                    Text("Not needed").font(.caption).foregroundStyle(.secondary)
                        .help("No game needs this version any more. It's removed with the next update.")
                }
            }
        }
        .contextMenu {
            if !model.activeComponentIDs.contains(component.id) {
                Button("Make Active") { model.makeActive(component) }
                    .help("Use this version for new games and games that follow updates. Choosing an older version keeps this component there: automatic updates skip it.")
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([component.directory]) }
            Button("Move to Trash", role: .destructive) { model.removeComponent(component) }
        }
    }
}

/// Shown above the component list only when there's something to act on: several updates at
/// once, a source that couldn't be checked, the result of an update, or old versions to remove.
struct ComponentUpdateNotices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if hasNotices {
            Section {
                if model.componentUpdates.count > 1 {
                    HStack {
                        Text("\(model.componentUpdates.count) updates available")
                        Spacer()
                        Button("Update All") { model.installComponentUpdates(model.componentUpdates) }
                            .disabled(model.busyMessage != nil)
                    }
                }
                ForEach(model.componentCheckFailures.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                    Label("Couldn't check \(name) for updates", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(reason)
                }
                if let message = model.componentUpdateMessage, message != "Everything is up to date." {
                    Text(message).foregroundStyle(.secondary)
                }
                if !model.unusedComponents.isEmpty {
                    HStack {
                        Text(model.unusedComponents.count == 1 ? "1 old version no game needs" : "\(model.unusedComponents.count) old versions no game needs")
                            .foregroundStyle(.secondary)
                            .help(model.unusedComponents.map(\.manifest.displayName).joined(separator: ", "))
                        Spacer()
                        Button("Remove") { model.removeUnusedComponents() }
                            .disabled(model.busyMessage != nil)
                    }
                }
            }
        }
    }

    private var hasNotices: Bool {
        model.componentUpdates.count > 1 || !model.componentCheckFailures.isEmpty || !model.unusedComponents.isEmpty
            || (model.componentUpdateMessage.map { $0 != "Everything is up to date." } ?? false)
    }
}

/// Settings ▸ Updates ▸ Distiller: this copy's version, and a newer release from the repository
/// it was built from.
struct AppUpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("Version", value: DistillerVersion.current)
            if let release = model.appUpdate {
                LabeledContent("Distiller \(release.version) is available") {
                    HStack {
                        Link("Release Notes", destination: release.page)
                        Button("Install and Relaunch") { model.installAppUpdate(release) }
                            .disabled(model.isInstallingAppUpdate)
                    }
                }
            }
            if let status = model.appUpdateStatus {
                HStack {
                    if model.isInstallingAppUpdate { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Distiller")
        } footer: {
            Group {
                if let repository = model.appUpdateRepository {
                    Text("Updates come from the releases of github.com/\(repository). Before installing one, Distiller checks the download against the release's checksums, and that it's signed by the same developer as this copy and notarized by Apple. The copy it replaces goes to the Trash.")
                } else {
                    Text("This build doesn't say where its updates come from (it wasn't built from a GitHub repository), so it can't check for them.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings ▸ Updates: how Distiller keeps Wine builds, graphics layers and winetricks up to date.
struct ComponentUpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Picker("Component updates", selection: Binding(get: { model.componentUpdateMode }, set: { model.setComponentUpdateMode($0) })) {
                ForEach(ComponentUpdateMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Picker("Keep restore points", selection: Binding(get: { model.restorePointDays }, set: { model.setRestorePointDays($0) })) {
                ForEach(RestorePointRetention.choices, id: \.self) { days in
                    Text(RestorePointRetention.describe(days)).tag(days)
                }
            }
            .help("Before a game moves to a newer Wine, Distiller saves a copy of its bottle so the move can be undone.")
            LabeledContent("Last checked") {
                HStack {
                    Text(model.lastComponentCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                        .foregroundStyle(.secondary)
                    Button("Check Now") { model.checkForComponentUpdates() }
                        .disabled(model.isCheckingForUpdates || model.busyMessage != nil)
                }
            }
        } header: {
            Text("Wine builds, graphics layers and winetricks")
        } footer: {
            Text("Distiller checks for these and for itself when it starts and once a day (a new Distiller always waits for you to install it, since that restarts the app). An update installs next to the version it replaces and becomes the active one: new games use it, and games move to it the next time they start. Before a game moves to a newer Wine, Distiller saves a copy of its bottle (a restore point) and asks after its first session whether it works; It Works removes the copy, Roll Back puts it back. A copy takes almost no space at first and grows only as the game's bottle changes. Versions no game needs are then removed. D3DMetal and Wine builds you imported aren't checked, since they come from your own downloads.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ImportWineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: URL

    @State private var id = "winehq"
    @State private var family = "winehq"
    @State private var version = ""
    @State private var arch: CPUArch = .x86_64

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: source.lastPathComponent)
                TextField("Identifier", text: $id)
                Picker("Family", selection: $family) {
                    Text("WineHQ").tag("winehq")
                    Text("CrossOver source").tag("crossover")
                    Text("Game Porting Toolkit").tag("gptk")
                }
                TextField("Version", text: $version, prompt: Text("11.0"))
                Picker("Architecture", selection: $arch) {
                    ForEach(CPUArch.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Import Wine build")
            } footer: {
                Text("Recipes ask for a family and a minimum version, so match the build you downloaded.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    let manifest = ComponentManifest(
                        id: id, kind: .wine, version: version,
                        displayName: "Wine \(version) (\(family))", arch: arch, family: family
                    )
                    model.importComponent(from: source, manifest: manifest)
                    dismiss()
                }
                .disabled(id.isEmpty || version.isEmpty)
            }
        }
    }
}

/// A chosen file waiting for the import sheet.
struct PendingImport: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
