import SwiftUI
import DistillerCommunity
import DistillerCore

/// Confirms installing a catalogue recipe that a `distiller://install` link asked for.
/// Nothing is downloaded or installed until the player clicks Install.
struct LinkInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: LinkInstallRequest

    var body: some View {
        let game = request.game
        let recipe = request.recipe
        let copies = model.installedCopies(of: request)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CommunityPicture(url: model.repository.mediaURL(game.icon), cornerRadius: 10) {
                    Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install \(game.title)?").font(.title2.weight(.semibold))
                    Text([recipe.name ?? recipe.id, graphicsName(recipe.graphics), rating(recipe)].joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }

            if let cover = model.repository.mediaURL(recipe.cover) {
                CommunityPicture(url: cover) { ProgressView() }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(installerText(game), systemImage: "arrow.down.circle")
                Label("Distiller downloads this recipe from the community catalogue, makes a new bottle for the game and applies the recipe's settings.", systemImage: "shippingbox")
                Label("Windows programs run with your permissions; Wine isn't a sandbox. Install games you trust.", systemImage: "exclamationmark.shield")
                if !copies.isEmpty {
                    Label("You already have \(copies.count == 1 ? "a copy" : "\(copies.count) copies") of this recipe in your library. Installing again makes another.", systemImage: "square.on.square")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !copies.isEmpty {
                    Button("Show in Library") {
                        model.sidebarSelection = .library
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copies.isEmpty ? "Install" : "Install Another Copy") {
                    model.installFromCommunity(recipe)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func installerText(_ game: IndexGame) -> String {
        if let url = game.officialInstaller?.url.flatMap({ URL(string: $0) }), let host = url.host {
            return "The game is installed from its publisher's official installer, \(url.lastPathComponent), downloaded from \(host)."
        }
        if let page = game.officialInstaller?.page.flatMap({ URL(string: $0) }), let host = page.host {
            return "The game is installed from its publisher's official installer. Distiller opens its download page on \(host) for you to download it."
        }
        return "The game is installed as the recipe describes."
    }

    private func graphicsName(_ id: String) -> String {
        GraphicsBackend(rawValue: id)?.displayName ?? id
    }

    private func rating(_ recipe: IndexRecipe) -> String {
        guard let tier = recipe.summary.tier else { return "Not rated yet" }
        return "\(tier.displayName) (\(recipe.summary.reports) report\(recipe.summary.reports == 1 ? "" : "s"))"
    }
}
