import SwiftUI
import DistillerCommunity
import DistillerCore

struct CommunityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let query = model.communityQuery
        return Group {
            if let index = model.index {
                let games = index.games.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                if games.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(games) { game in
                        Section {
                            if let hardware = model.hardware {
                                ForEach(RecipeRanker.rank(game.recipes, for: hardware)) { ranked in
                                    CommunityRecipeRow(ranked: ranked)
                                }
                            }
                        } header: {
                            CommunityGameHeader(game: game)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No community recipes yet", systemImage: "person.2")
                } description: {
                    Text("Download the recipe index to see what other players have shared and how it ran on their Macs.")
                } actions: {
                    Button("Download Recipes") { model.refreshCommunity() }
                }
            }
        }
        .navigationTitle("Community")
        .searchable(text: $model.communityQuery, prompt: "Search games")
        .toolbar {
            Button {
                model.refreshCommunity()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Download the latest recipes and reports")
        }
    }
}

/// A game's icon, title and catalogue details above its recipes.
struct CommunityGameHeader: View {
    @Environment(AppModel.self) private var model
    let game: IndexGame

    var body: some View {
        HStack(spacing: 10) {
            CommunityPicture(url: model.repository.mediaURL(game.icon), cornerRadius: 7) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.headline).foregroundStyle(.primary)
                let facts = [game.publisher, game.releaseYear.map(String.init), game.genres?.joined(separator: ", ")].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }
}

/// A picture from the catalogue, with a placeholder while it loads or when there isn't one.
struct CommunityPicture<Placeholder: View>: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        background
                    }
                }
            } else {
                background
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary).overlay { placeholder() }
    }
}

struct CommunityRecipeRow: View {
    @Environment(AppModel.self) private var model
    let ranked: RankedRecipe
    @State private var isShowingScreenshot = false

    var body: some View {
        HStack(spacing: 16) {
            let screenshots = (ranked.recipe.screenshots ?? []).compactMap { model.repository.mediaURL($0) }
            if let cover = screenshots.first {
                CommunityPicture(url: cover) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
                .frame(width: 128, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if screenshots.count > 1 {
                        Text("\(screenshots.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { isShowingScreenshot = true }
                .help("Screenshots from the recipe's test run. Click to enlarge.")
                .popover(isPresented: $isShowingScreenshot) {
                    ScreenshotGallery(urls: screenshots)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ranked.recipe.name ?? ranked.recipe.id)
                Text([ranked.tier?.displayName ?? "Unrated", ranked.evidence, ranked.recipe.graphics].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install") { model.installFromCommunity(ranked.recipe) }
        }
        .padding(.vertical, 4)
    }
}

/// A recipe's screenshots, large, with thumbnails to switch between them.
struct ScreenshotGallery: View {
    let urls: [URL]
    @State private var selected = 0

    var body: some View {
        VStack(spacing: 8) {
            CommunityPicture(url: urls[min(selected, urls.count - 1)]) { ProgressView() }
                .frame(width: 800, height: 450)
            if urls.count > 1 {
                HStack(spacing: 8) {
                    ForEach(urls.indices, id: \.self) { index in
                        CommunityPicture(url: urls[index]) { Color.clear }
                            .frame(width: 96, height: 54)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(index == selected ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .onTapGesture { selected = index }
                    }
                }
            }
        }
        .padding(8)
    }
}
