import SwiftUI
import DistillerCore

struct BottlesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Bottle.ID?

    var body: some View {
        Group {
            if model.bottles.isEmpty {
                ContentUnavailableView(
                    "No bottles yet",
                    systemImage: "shippingbox",
                    description: Text("Each game you add gets its own bottle, an isolated Windows environment.")
                )
            } else {
                Table(model.bottles, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Wine build", value: \.wine)
                    TableColumn("Created") { bottle in
                        Text(bottle.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .contextMenu(forSelectionType: Bottle.ID.self) { ids in
                    if let id = ids.first {
                        Button("Show in Finder") { model.revealBottle(id: id) }
                    }
                }
            }
        }
        .navigationTitle("Bottles")
    }
}
