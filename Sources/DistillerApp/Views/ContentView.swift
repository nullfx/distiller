import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DistillerCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case library = "My Library"
    case community = "Community"
    case bottles = "Bottles"
    case components = "Components"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .library: return "gamecontroller"
        case .community: return "person.2"
        case .bottles: return "shippingbox"
        case .components: return "square.stack.3d.up"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.sidebarSelection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .components ? model.componentUpdates.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if let hardware = model.hardware {
                    Text(hardware.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .help("Report key: \(hardware.hardwareKey)")
                }
            }
        } detail: {
            switch model.sidebarSelection ?? .library {
            case .library: LibraryView()
            case .community: CommunityView()
            case .bottles: BottlesView()
            case .components: ComponentsView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            UnavailableStorageBanner()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                GitHubToolbarButton()
            }
        }
        // Notice drives being connected or disconnected, and changes made outside the app.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        .safeAreaInset(edge: .bottom) {
            if let message = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .alert(
            "That didn't work",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Distiller \(model.appUpdateToAnnounce?.version ?? "") is available",
            isPresented: Binding(get: { model.appUpdateToAnnounce != nil }, set: { if !$0 { model.appUpdateToAnnounce = nil } }),
            presenting: model.appUpdateToAnnounce
        ) { release in
            Button("Install and Relaunch") { model.installAppUpdate(release) }
            Button("Release Notes") { NSWorkspace.shared.open(release.page) }
            Button("Later", role: .cancel) {}
        } message: { release in
            Text("You have \(DistillerVersion.current). You can also install it later from Settings ▸ Updates.")
        }
        .alert(
            model.updateCheckSummary?.title ?? "",
            isPresented: Binding(get: { model.updateCheckSummary != nil }, set: { if !$0 { model.updateCheckSummary = nil } }),
            presenting: model.updateCheckSummary
        ) { summary in
            if summary.hasComponentUpdates {
                Button("Show Components") { model.sidebarSelection = .components }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { summary in
            Text(summary.message)
        }
        .alert(
            "Did \(model.restorePointQuestion?.game.title ?? "the game") work on \(model.restorePointQuestion.map { RestorePoint.describe($0.point.toWine) } ?? "the new Wine")?",
            isPresented: Binding(get: { model.restorePointQuestion != nil }, set: { if !$0 { model.restorePointQuestion = nil } }),
            presenting: model.restorePointQuestion
        ) { question in
            Button("It Works") { model.confirmWineMove(question.game) }
            Button("Roll Back") { model.rollBack(question.game) }
            Button("Not Sure Yet", role: .cancel) {}
        } message: { question in
            Text("Distiller saved a copy of its bottle before moving it from \(RestorePoint.describe(question.point.fromWine)). Roll Back puts that copy back and keeps the game on \(RestorePoint.describe(question.point.fromWine)). You can also decide later in the recipe workshop's Bottle tab.")
        }
        .alert(
            "Does \(model.rebuildQuestion?.title ?? "the game") work in its rebuilt bottle?",
            isPresented: Binding(get: { model.rebuildQuestion != nil }, set: { if !$0 { model.rebuildQuestion = nil } }),
            presenting: model.rebuildQuestion
        ) { game in
            Button("Keep New Bottle") { model.keepRebuild(game) }
            Button("Switch Back") { model.switchBack(game) }
            Button("Not Sure Yet", role: .cancel) {}
        } message: { game in
            Text("Keep New Bottle moves the old bottle to the Trash. Switch Back returns to the old bottle and removes the new one. You can also decide later in the recipe workshop's Bottle tab.")
        }
        .fileImporter(isPresented: $model.isImportingRecipe, allowedContentTypes: [.yaml]) { result in
            if case .success(let url) = result { model.addGame(fromRecipeFile: url) }
        }
        .sheet(item: $model.gameToReport) { game in
            ReportSheet(game: game)
        }
        .sheet(isPresented: $model.isShowingSetup) {
            SetupAssistantView()
        }
        .sheet(isPresented: $model.isCreatingRecipe) {
            RecipeBuilderView()
        }
        .sheet(item: $model.gameInWorkshop) { game in
            RecipeWorkshopView(gameID: game.id)
        }
        .sheet(item: $model.gameToSubmit) { game in
            SubmitRecipeView(gameID: game.id)
        }
        .sheet(item: $model.linkInstall) { request in
            LinkInstallSheet(request: request)
        }
    }
}
