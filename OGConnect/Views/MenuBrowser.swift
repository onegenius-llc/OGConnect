import SwiftUI

private struct MenuDestination: Hashable {
    var path: [Int]
    var title: String
}

/// The Mac app's menu bar as a drop-down: pick a menu, then an item, and it's triggered on the Mac.
/// Each level is fetched when it's opened, so enabled states and checkmarks are current.
struct MenuBrowser: View {
    @ObservedObject var session: RemoteSession
    let appName: String
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            MenuLevel(session: session, path: [], title: appName, dismiss: dismiss)
                .navigationDestination(for: MenuDestination.self) { destination in
                    MenuLevel(session: session, path: destination.path, title: destination.title, dismiss: dismiss)
                }
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 520, idealHeight: 620)
    }
}

private struct MenuLevel: View {
    @ObservedObject var session: RemoteSession
    let path: [Int]
    let title: String
    let dismiss: () -> Void

    /// Items split into groups wherever the Mac menu has a separator line.
    private var groups: [[MenuItemInfo]] {
        guard let items = session.menus[path]?.items else { return [] }
        return items.split(whereSeparator: \.isSeparator).map(Array.init)
    }

    var body: some View {
        List {
            ForEach(groups, id: \.first?.index) { group in
                Section {
                    ForEach(group) { item in
                        row(item)
                    }
                }
            }
        }
        .overlay {
            if let listing = session.menus[path] {
                if let error = listing.error {
                    ContentUnavailableView("Menus Unavailable", systemImage: "menubar.rectangle", description: Text(error))
                } else if listing.items.isEmpty {
                    ContentUnavailableView("Empty Menu", systemImage: "menubar.rectangle")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.requestMenu(path: path) }
    }

    @ViewBuilder
    private func row(_ item: MenuItemInfo) -> some View {
        if item.hasSubmenu {
            NavigationLink(value: MenuDestination(path: path + [item.index], title: item.title)) {
                Text(item.title)
            }
            .disabled(!item.enabled)
        } else {
            Button {
                session.performMenu(path: path + [item.index], title: item.title)
                dismiss()
            } label: {
                HStack {
                    Text(item.title)
                        .foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                    Spacer()
                    if item.checked {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .disabled(!item.enabled)
        }
    }
}
