import SwiftUI

struct WindowListView: View {
    @ObservedObject var session: RemoteSession
    let title: String

    @State private var showsAppPicker = false

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 20)]

    private var appWindows: [WindowInfo] { session.windows.filter { $0.isMenuBarItem != true } }
    private var menuBarItems: [WindowInfo] { session.windows.filter { $0.isMenuBarItem == true } }

    var body: some View {
        ScrollView {
            if let hello = session.hello, !hello.canCapture || !hello.canControl {
                permissionNotice(hello)
            }
            if !menuBarItems.isEmpty {
                menuBar
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(appWindows) { window in
                    NavigationLink(value: Route.viewer(window)) {
                        WindowCard(window: window, thumbnail: session.thumbnails[window.id])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .overlay {
            if session.isLocked {
                LockedView(session: session)
            } else if session.windows.isEmpty {
                if session.isLoadingWindows {
                    ProgressView("Loading windows…")
                } else {
                    ContentUnavailableView("No Windows", systemImage: "macwindow",
                                           description: Text("There are no open windows on the Mac's current desktop."))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsAppPicker = true
                } label: {
                    Label("Open App", systemImage: "plus.app")
                }
                .disabled(session.isLocked)

                Button {
                    session.refreshWindows()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showsAppPicker) {
            AppPickerView(session: session)
        }
        .onAppear { session.refreshWindows() }
    }

    /// The Mac's menu bar items. Opening one clicks it on the Mac and shows what drops down.
    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar")
                .font(.headline)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(menuBarItems) { item in
                        NavigationLink(value: Route.viewer(item)) {
                            MenuBarChip(item: item, image: session.thumbnails[item.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 16)
    }

    private func permissionNotice(_ hello: ServerHello) -> some View {
        Label {
            Text(hello.canCapture
                 ? "OGConnect Server doesn't have Accessibility permission on \(hello.name), so you can watch windows but not control them."
                 : "OGConnect Server doesn't have Screen Recording permission on \(hello.name), so it can't share windows.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 20)
    }
}

/// Shown instead of the window list while the Mac is at its lock screen.
private struct LockedView: View {
    @ObservedObject var session: RemoteSession
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("\(session.hello?.name ?? "The Mac") is Locked")
                .font(.title2.bold())
            Text("Enter the password for your Mac user account to unlock it. It's sent only to your Mac and isn't saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .submitLabel(.go)
                .onSubmit(unlock)
            if let message = session.unlockMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button(action: unlock) {
                if session.isUnlocking {
                    ProgressView()
                } else {
                    Text("Unlock")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || session.isUnlocking)
        }
        .padding(32)
        .frame(maxWidth: 460)
    }

    private func unlock() {
        guard !password.isEmpty, !session.isUnlocking else { return }
        session.unlock(password: password)
        password = ""
    }
}

private struct MenuBarChip: View {
    let item: WindowInfo
    let image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            // The picture is a cut-out of the Mac's own menu bar, background included.
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(5)
                }
            }
            .frame(width: 72, height: 44)

            Text(item.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 76)
        }
        .contentShape(Rectangle())
    }
}

private struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                } else {
                    Image(systemName: "macwindow")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(window.appName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
    }
}
