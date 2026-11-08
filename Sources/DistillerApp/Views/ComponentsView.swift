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
        .toolbar {
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
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([component.directory]) }
            Button("Move to Trash", role: .destructive) { model.removeComponent(component) }
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
