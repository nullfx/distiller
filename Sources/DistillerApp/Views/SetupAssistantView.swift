import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DistillerCore

/// First-run setup: checks for Rosetta, Wine, winetricks, cabextract and D3DMetal, and
/// installs what it can. Shown at launch while something required is missing, and from
/// the Distiller menu and Components at any time.
struct SetupAssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var wineSource: WineSource = .recommended
    @State private var isImportingGPTK = false

    var body: some View {
        let report = model.environment
        VStack(spacing: 0) {
            Form {
                StorageLocationsSection()
                if !model.storageConfirmed {
                    Section {
                        HStack {
                            Text("Choose these first: Wine and anything you install go to the locations above.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Use These Locations") { model.confirmStorageLocations() }
                                .disabled(!model.unavailableStorage.isEmpty)
                        }
                    }
                }

                Section {
                    ForEach(report?.items ?? []) { status in
                        SetupRow(status: status, wineSource: $wineSource) {
                            if status.item == .d3dmetal {
                                isImportingGPTK = true
                            } else {
                                model.install(status.item, wineSource: wineSource)
                            }
                        }
                    }
                } header: {
                    Text("Set up Distiller")
                } footer: {
                    Text(footer(report))
                }
                .disabled(!model.storageConfirmed)

                if report?.status(.d3dmetal)?.isInstalled == false {
                    Section("D3DMetal") {
                        Text("Apple doesn't allow D3DMetal to be shared, so you download the Game Porting Toolkit yourself with a free Apple developer account, then import its disk image here.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Apple's Download Page") { NSWorkspace.shared.open(EnvironmentSetup.gptkDownloadPage) }
                            Button("Import Disk Image…") { isImportingGPTK = true }
                        }
                    }
                    .disabled(!model.storageConfirmed)
                }
            }
            .formStyle(.grouped)
            .disabled(model.busyMessage != nil)

            HStack {
                if let message = model.busyMessage {
                    ProgressView().controlSize(.small)
                    Text(message).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer()
                Button(report?.isReady == true ? "Done" : "Skip for Now") { model.dismissSetup() }
                    .keyboardShortcut(.cancelAction)
                Button("Install Everything Missing") { model.installAllMissing(wineSource: wineSource) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.storageConfirmed || model.busyMessage != nil || report.map { $0.missing.allSatisfy { !$0.canInstallAutomatically } } ?? true)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .onAppear { model.checkEnvironment() }
        .fileImporter(isPresented: $isImportingGPTK, allowedContentTypes: [.diskImage, .folder, .volume]) { result in
            if case .success(let url) = result {
                model.importGPTK(from: url)
            }
        }
    }

    private func footer(_ report: EnvironmentReport?) -> String {
        guard let report else { return "Checking this Mac…" }
        if report.isComplete { return "Everything is set up." }
        if report.isReady { return "Games can run now. The optional items make more games work." }
        return "Rosetta and Wine are required. Installing Rosetta asks for your administrator password. Wine runs Windows programs with your permissions; it isn't a sandbox."
    }
}

private struct SetupRow: View {
    let status: SetupStatus
    @Binding var wineSource: WineSource
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isInstalled ? "checkmark.circle.fill" : (status.item.isRequired ? "xmark.circle" : "circle.dashed"))
                .foregroundStyle(status.isInstalled ? .green : (status.item.isRequired ? .red : .secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(status.item.displayName).font(.headline)
                    if !status.item.isRequired { Text("Optional").font(.caption).foregroundStyle(.secondary) }
                }
                Text(status.item.purpose).font(.callout).foregroundStyle(.secondary)
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                if status.item == .wine && !status.isInstalled {
                    Picker("Build", selection: $wineSource) {
                        ForEach(WineSource.all) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Text(wineSource.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !status.isInstalled {
                Button(status.item == .d3dmetal ? "Import…" : "Install", action: action)
            }
        }
        .padding(.vertical, 4)
    }
}
