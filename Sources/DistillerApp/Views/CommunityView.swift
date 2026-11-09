import AppKit
import SwiftUI
import DistillerCommunity
import DistillerCore

/// Community: the catalogue's games, and a page for each with its screenshots, details,
/// recipes and reports (the same as the game's page on the website), before installing.
struct CommunityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.communityPath) {
            CommunityGameList()
                .navigationDestination(for: String.self) { slug in
                    CommunityGameView(slug: slug)
                }
        }
    }
}

private struct CommunityGameList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return Group {
            if let index = model.index {
                let games = CatalogueBrowser.games(index.games, query: model.communityQuery, filter: model.communityFilter)
                Group {
                    if games.isEmpty {
                        if model.communityFilter.isNarrowing {
                            ContentUnavailableView {
                                Label("No matching games", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("No games match these filters\(model.communityQuery.isEmpty ? "" : " and “\(model.communityQuery)”").")
                            } actions: {
                                Button("Clear Filters") { model.communityFilter = CatalogueFilter(sort: model.communityFilter.sort) }
                            }
                        } else {
                            ContentUnavailableView.search(text: model.communityQuery)
                        }
                    } else {
                        List(games) { game in
                            NavigationLink(value: game.slug) {
                                CommunityGameRow(game: game)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    CommunityFilterBar(facets: CatalogueBrowser.facets(index.games), shown: games.count, total: index.games.count)
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
        .searchable(text: $model.communityQuery, prompt: "Search games, publishers, descriptions")
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

/// Genre, graphics layer, rating and order, as on the website's games page. The menus sit in
/// a row when there's room, and fold into one Filter menu when the window is narrow.
private struct CommunityFilterBar: View {
    @Environment(AppModel.self) private var model
    let facets: (genres: [String], graphics: [String])
    let shown: Int
    let total: Int

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        genrePicker.fixedSize()
                        graphicsPicker.fixedSize()
                        ratingPicker.fixedSize()
                        sortPicker.fixedSize()
                    }
                    HStack(spacing: 8) {
                        Menu {
                            genrePicker
                            graphicsPicker
                            ratingPicker
                        } label: {
                            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .fixedSize()
                        sortPicker.fixedSize()
                    }
                }
                Spacer(minLength: 8)
                if model.communityFilter.isNarrowing {
                    Button("Clear") { model.communityFilter = CatalogueFilter(sort: model.communityFilter.sort) }
                        .controlSize(.small)
                }
                Text(shown == total ? (total == 1 ? "1 game" : "\(total) games") : "\(shown) of \(total) games")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }

    private var filter: Binding<CatalogueFilter> {
        Binding(get: { model.communityFilter }, set: { model.communityFilter = $0 })
    }

    private var genrePicker: some View {
        Picker("Genre", selection: filter.genre) {
            Text("All genres").tag(String?.none)
            ForEach(facets.genres, id: \.self) { Text(CatalogueText.genre($0)).tag(String?.some($0)) }
        }
        .labelsHidden()
        .help("Genre")
    }

    private var graphicsPicker: some View {
        Picker("Graphics layer", selection: filter.graphics) {
            Text("Any graphics layer").tag(String?.none)
            ForEach(facets.graphics, id: \.self) { Text(CatalogueText.graphics($0)).tag(String?.some($0)) }
        }
        .labelsHidden()
        .help("Graphics layer")
    }

    private var ratingPicker: some View {
        Picker("Rating", selection: filter.minimumTier) {
            Text("Any rating").tag(PlayabilityTier?.none)
            Text("Platinum").tag(PlayabilityTier?.some(.platinum))
            Text("Gold or better").tag(PlayabilityTier?.some(.gold))
            Text("Silver or better").tag(PlayabilityTier?.some(.silver))
            Text("Bronze or better").tag(PlayabilityTier?.some(.bronze))
        }
        .labelsHidden()
        .help("Rating")
    }

    private var sortPicker: some View {
        Picker("Sort", selection: filter.sort) {
            ForEach(CatalogueSort.allCases) { Text("Sort: \($0.displayName)").tag($0) }
        }
        .labelsHidden()
        .help("Order")
    }
}

/// A game in the list: icon, title, facts, rating, and the best recipe's cover.
private struct CommunityGameRow: View {
    @Environment(AppModel.self) private var model
    let game: IndexGame

    var body: some View {
        HStack(spacing: 12) {
            CommunityPicture(url: model.repository.mediaURL(game.icon), cornerRadius: 8) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline)
                let facts = [game.publisher, game.releaseYear.map(String.init), game.genres.map { $0.map(CatalogueText.genre).joined(separator: ", ") }].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    TierBadge(tier: game.summary?.tier, reports: game.summary?.reports ?? 0)
                    Text(game.recipes.count == 1 ? "1 recipe" : "\(game.recipes.count) recipes")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let cover = game.recipes.compactMap(\.cover).first.flatMap(model.repository.mediaURL) {
                CommunityPicture(url: cover) { Color.clear }
                    .frame(width: 96, height: 54)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - A game's page

struct CommunityGameView: View {
    @Environment(AppModel.self) private var model
    let slug: String
    @State private var detail: CommunityGameDetail?
    @State private var detailError: String?
    @State private var enlarged: EnlargedScreenshots?

    var body: some View {
        if let game = model.index?.games.first(where: { $0.slug == slug }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(game)
                    let shots = screenshots(game)
                    if !shots.isEmpty { gallery(shots) }
                    installPanel(game)
                    if let description = game.description, !description.isEmpty {
                        section("About the game") {
                            Text(description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    links(game)
                    recipes(game)
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(game.title)
            .task(id: slug) { await loadDetail(game) }
            .sheet(item: $enlarged) { shots in
                VStack(spacing: 0) {
                    ScreenshotGallery(urls: shots.urls, selected: shots.index)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
            }
        } else {
            ContentUnavailableView("Not in the catalogue", systemImage: "questionmark.square.dashed",
                                   description: Text("This game isn't in the community catalogue. It may have been removed or renamed."))
        }
    }

    // MARK: Sections

    private func header(_ game: IndexGame) -> some View {
        HStack(alignment: .center, spacing: 16) {
            CommunityPicture(url: model.repository.mediaURL(game.icon), cornerRadius: 14) {
                Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.secondary)
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.title).font(.largeTitle.bold()).textSelection(.enabled)
                let facts = [
                    game.publisher.map { "Published by \($0)" },
                    game.developer.flatMap { $0 == game.publisher ? nil : "Developed by \($0)" },
                    game.releaseYear.map(String.init),
                    game.genres.map { $0.map(CatalogueText.genre).joined(separator: ", ") },
                ].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                TierBadge(tier: game.summary?.tier, reports: game.summary?.reports ?? 0)
            }
        }
    }

    private func screenshots(_ game: IndexGame) -> [URL] {
        ranked(game).flatMap { ($0.recipe.screenshots ?? []).compactMap(model.repository.mediaURL) }
    }

    private func gallery(_ shots: [URL]) -> some View {
        InlineGallery(urls: shots) { index in enlarged = EnlargedScreenshots(urls: shots, index: index) }
    }

    @ViewBuilder private func installPanel(_ game: IndexGame) -> some View {
        if let best = ranked(game).first {
            GroupBox {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Play it on your Mac").font(.headline)
                        Text("Best for this Mac: \(best.recipe.name ?? best.recipe.id) (\(CatalogueText.graphics(best.recipe.graphics))).")
                            .foregroundStyle(.secondary)
                        if let host = game.officialInstaller?.url.flatMap({ URL(string: $0)?.host }) {
                            Text("Installs from the publisher's official installer (\(host)). Distiller asks before it installs anything.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let host = game.officialInstaller?.page.flatMap({ URL(string: $0)?.host }) {
                            Text("Installs from the publisher's official installer, which you download from its page on \(host). Distiller asks before it installs anything.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let copies = model.installedCopies(of: LinkInstallRequest(game: game, recipe: best.recipe))
                        if !copies.isEmpty {
                            Text(copies.count == 1 ? "Already in your library." : "\(copies.count) copies are already in your library.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Install…") { model.linkInstall = LinkInstallRequest(game: game, recipe: best.recipe) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(6)
            }
        }
    }

    @ViewBuilder private func links(_ game: IndexGame) -> some View {
        let website = CatalogueText.safeLink(game.website)
        let stores = (game.stores ?? []).compactMap { store in CatalogueText.safeLink(store.url).map { (CatalogueText.store(store.name), $0) } }
        let installer = CatalogueText.safeLink(game.officialInstaller?.url)
        let downloadPage = CatalogueText.safeLink(game.officialInstaller?.page)
        if website != nil || !stores.isEmpty || installer != nil || downloadPage != nil {
            section("Links") {
                VStack(alignment: .leading, spacing: 6) {
                    if let website { Link("Official website", destination: website) }
                    ForEach(stores, id: \.1) { name, url in Link(name, destination: url) }
                    if let downloadPage { Link("Download page", destination: downloadPage) }
                    if let installer {
                        HStack(spacing: 4) {
                            Link("Official installer", destination: installer)
                            Text("(\(installer.host ?? ""))").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func recipes(_ game: IndexGame) -> some View {
        let list = ranked(game)
        return section("Recipes (\(list.count))") {
            VStack(alignment: .leading, spacing: 14) {
                if let detailError {
                    HStack {
                        Label(detailError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadDetail(game) } }
                    }
                    .font(.callout)
                }
                ForEach(list, id: \.recipe.id) { entry in
                    CommunityRecipeCard(game: game, entry: entry, detail: detail?.recipe(entry.recipe.id), detailLoaded: detail != nil)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            content()
        }
    }

    // MARK: Data

    /// The game's recipes, best for this Mac first (in catalogue order if the Mac is unknown).
    private func ranked(_ game: IndexGame) -> [RecipeEntry] {
        guard let hardware = model.hardware else {
            return game.recipes.map { RecipeEntry(recipe: $0, tier: $0.summary.tier, evidence: nil) }
        }
        return RecipeRanker.rank(game.recipes, for: hardware).map { RecipeEntry(recipe: $0.recipe, tier: $0.tier, evidence: $0.evidence) }
    }

    private func loadDetail(_ game: IndexGame) async {
        guard let community = model.community else { return }
        do {
            detail = try await community.fetchDetail(for: game)
            detailError = nil
        } catch {
            detailError = "Recipe details and reports couldn't be downloaded."
        }
    }
}

/// A recipe in a game's page, with the rating that applies to this Mac.
struct RecipeEntry {
    var recipe: IndexRecipe
    var tier: PlayabilityTier?
    /// How the rating was worked out ("2 reports from Macs like yours").
    var evidence: String?
}

private struct EnlargedScreenshots: Identifiable {
    let urls: [URL]
    let index: Int
    var id: String { "\(index)-\(urls.map(\.absoluteString).joined())" }
}

/// One recipe: its rating, settings, recipe file, and how it ran on different Macs.
private struct CommunityRecipeCard: View {
    @Environment(AppModel.self) private var model
    let game: IndexGame
    let entry: RecipeEntry
    let detail: DetailRecipe?
    let detailLoaded: Bool
    @State private var showsFile = false
    @State private var fileText: String?
    @State private var fileError = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        let name = entry.recipe.name.flatMap { $0 == game.title ? nil : $0 }
                        Text(name.map { "\($0) (\(entry.recipe.id))" } ?? entry.recipe.id).font(.headline)
                        HStack(spacing: 8) {
                            TierBadge(tier: entry.tier, reports: entry.recipe.summary.reports)
                            Text(CatalogueText.graphics(entry.recipe.graphics))
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                            if let authors = detail?.recipe?.authors, !authors.isEmpty {
                                Text("by \(authors.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let evidence = entry.evidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Install…") { model.linkInstall = LinkInstallRequest(game: game, recipe: entry.recipe) }
                }
                if let notes = detail?.recipe?.notes, !notes.isEmpty {
                    Text(notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let recipe = detail?.recipe {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(CatalogueText.settings(of: recipe).enumerated()), id: \.offset) { _, line in
                            GridRow {
                                Text(line.label).foregroundStyle(.secondary)
                                Text(line.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                } else if !detailLoaded {
                    ProgressView().controlSize(.small)
                }
                DisclosureGroup("Recipe file", isExpanded: $showsFile) { recipeFile }
                    .onChange(of: showsFile) { _, open in if open { Task { await loadFile() } } }
                hardwareTable
                reports
            }
            .padding(6)
        }
    }

    @ViewBuilder private var recipeFile: some View {
        if let fileText {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(entry.recipe.path.replacingOccurrences(of: "recipes/", with: "")).font(.caption.bold())
                    Text("YAML").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(text: fileText)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView(.horizontal) {
                    Text(fileText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .padding(.top, 6)
        } else if fileError {
            HStack {
                Text("The recipe file couldn't be downloaded.").foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadFile() } }
            }
            .font(.callout)
            .padding(.top, 6)
        } else {
            ProgressView().controlSize(.small).padding(.top, 6)
        }
    }

    @ViewBuilder private var hardwareTable: some View {
        let rows = entry.recipe.byHardware.sorted { $0.key < $1.key }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("How it runs on different Macs").font(.subheadline.bold())
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Mac"); Text("Rating"); Text("Reports"); Text("Median FPS")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(rows, id: \.key) { key, summary in
                        GridRow {
                            Text(CatalogueText.hardware(key))
                            TierBadge(tier: summary.tier, reports: 0)
                            Text("\(summary.reports)").monospacedDigit()
                            Text(summary.medianFPS.map { String(Int($0.rounded())) } ?? "—").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder private var reports: some View {
        if let reports = detail?.reports, !reports.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reports").font(.subheadline.bold())
                ForEach(Array(reports.prefix(50).enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            TierBadge(tier: report.tier, reports: 0)
                            Text([report.date, report.hardwareKey.map(CatalogueText.hardware), report.fpsAverage.map { "\(Int($0.rounded())) FPS" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let notes = report.notes, !notes.isEmpty {
                            Text(notes).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } else if detailLoaded {
            Text("No reports yet.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadFile() async {
        guard fileText == nil, let community = model.community else { return }
        fileError = false
        do {
            fileText = try await community.fetchRecipeText(path: entry.recipe.path)
        } catch {
            fileError = true
        }
    }
}

// MARK: - Shared pieces

/// A rating with its colour ("● Gold · 3 reports"), or "Not rated".
struct TierBadge: View {
    let tier: PlayabilityTier?
    var reports = 0

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text((tier?.displayName ?? "Not rated") + (reports > 0 ? " · \(reports) report\(reports == 1 ? "" : "s")" : ""))
        }
        .font(.caption)
        .help(tier?.explanation ?? "No reports yet")
    }

    private var color: Color {
        switch tier {
        case .platinum: return Color(red: 0.55, green: 0.65, blue: 0.78)
        case .gold: return Color(red: 0.85, green: 0.65, blue: 0.13)
        case .silver: return Color(white: 0.62)
        case .bronze: return Color(red: 0.72, green: 0.45, blue: 0.2)
        case .borked: return .red
        case nil: return Color(white: 0.5).opacity(0.5)
        }
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

/// Screenshots on a game's page: a large one that fits the page's width, and thumbnails.
/// Clicking the large one shows it bigger.
private struct InlineGallery: View {
    let urls: [URL]
    let enlarge: (Int) -> Void
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommunityPicture(url: urls[min(selected, urls.count - 1)], cornerRadius: 10) { ProgressView() }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { enlarge(selected) }
                .help("Show the screenshot larger")
            if urls.count > 1 {
                HStack(spacing: 8) {
                    ForEach(urls.indices, id: \.self) { index in
                        CommunityPicture(url: urls[index]) { Color.clear }
                            .frame(width: 112, height: 63)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(index == selected ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selected = index }
                    }
                }
            }
            Text("Screenshots from community checks, where a contributor installed the game from its official installer and played it. Pictures belong to the game's publisher.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A recipe's screenshots, large, with thumbnails to switch between them.
struct ScreenshotGallery: View {
    let urls: [URL]
    @State var selected = 0

    var body: some View {
        VStack(spacing: 8) {
            CommunityPicture(url: urls[min(selected, urls.count - 1)]) { ProgressView() }
                .frame(width: 960, height: 540)
            if urls.count > 1 {
                HStack(spacing: 8) {
                    ForEach(urls.indices, id: \.self) { index in
                        CommunityPicture(url: urls[index]) { Color.clear }
                            .frame(width: 96, height: 54)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(index == selected ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selected = index }
                    }
                }
            }
        }
        .padding(12)
    }
}
