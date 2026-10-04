import SwiftUI

/// The Mac's installed apps; choosing one launches it there.
struct AppPickerView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var apps: [AppInfo] {
        guard !search.isEmpty else { return session.apps }
        return session.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(apps) { app in
                        Button {
                            session.launchApp(app.id)
                            dismiss()
                        } label: {
                            cell(app)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .overlay {
                if session.apps.isEmpty {
                    ProgressView()
                } else if apps.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search apps on the Mac")
            .navigationTitle("Open App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { session.requestApps() }
        }
    }

    private func cell(_ app: AppInfo) -> some View {
        VStack(spacing: 6) {
            Group {
                if let icon = session.appIcons[app.id] {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .padding(4)
                }
            }
            .frame(width: 64, height: 64)

            Text(app.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)

            // Marks apps that are already running, like the dot under a Dock icon.
            Circle()
                .fill(app.isRunning ? Color.secondary : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onAppear { session.requestAppIcon(app.id) }
    }
}
