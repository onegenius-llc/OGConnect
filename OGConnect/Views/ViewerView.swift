import SwiftUI

@MainActor
final class ViewerState: ObservableObject {
    @Published var keyboardVisible = false
    @Published var stickyModifiers: Modifiers = []
    @Published var hasVideo = false
    @Published var menuVisible = false
}

/// Shows one remote window and forwards input to it.
struct ViewerView: View {
    @ObservedObject var session: RemoteSession
    let window: WindowInfo
    @StateObject private var state = ViewerState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RemoteVideo(session: session, state: state, remotePointWidth: CGFloat(window.width))
            .overlay {
                if !state.hasVideo {
                    ProgressView("Starting…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .top) {
                if session.hello?.canControl == false {
                    Label("View only — OGConnect Server needs Accessibility permission on the Mac to click and type.",
                          systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.yellow, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.black)
            // The video view keeps itself clear of the keyboard, so SwiftUI mustn't also resize it.
            .ignoresSafeArea(.all, edges: [.horizontal, .bottom])
            .navigationTitle(window.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        session.resetMenus()
                        state.menuVisible = true
                    } label: {
                        Label("Menus", systemImage: "menubar.rectangle")
                    }
                    .popover(isPresented: $state.menuVisible) {
                        MenuBrowser(session: session, appName: window.appName) { state.menuVisible = false }
                    }

                    Button {
                        state.keyboardVisible.toggle()
                    } label: {
                        Label("Keyboard", systemImage: state.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                }
            }
            .onAppear { session.startStream(window) }
            .onDisappear { session.stopStream() }
            .onChange(of: scenePhase) { _, phase in
                // The decoder is torn down in the background; start again from a clean keyframe.
                if phase == .active {
                    session.renderer.reset()
                    session.requestKeyframe()
                }
            }
    }
}

private struct RemoteVideo: UIViewRepresentable {
    let session: RemoteSession
    @ObservedObject var state: ViewerState
    let remotePointWidth: CGFloat

    final class Coordinator {
        var keyBarHost: UIHostingController<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RemoteVideoView {
        let view = RemoteVideoView()

        let keyBar = KeyBar(session: session, state: state).environment(\.colorScheme, .dark)
        let host = UIHostingController(rootView: AnyView(keyBar))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        host.view.autoresizingMask = .flexibleWidth
        context.coordinator.keyBarHost = host
        view.keyBar = host.view
        view.remotePointWidth = remotePointWidth
        view.sendInput = { [weak session] event in session?.send(event) }
        view.stickyModifiers = { [weak state] in state?.stickyModifiers ?? [] }
        view.consumeStickyModifiers = { [weak state] in
            if let state, !state.stickyModifiers.isEmpty { state.stickyModifiers = [] }
        }
        session.renderer.attach(view.displayLayer)
        session.renderer.onVideoSize = { [weak view, weak state] size in
            view?.videoSize = size
            state?.hasVideo = true
        }
        return view
    }

    func updateUIView(_ view: RemoteVideoView, context: Context) {
        view.softKeyboardEnabled = state.keyboardVisible
        // The menu popover takes keyboard focus; take it back so keys reach the Mac again.
        if !state.menuVisible {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        }
    }
}

/// Keys the iPad's on-screen keyboard doesn't have. Modifiers latch and apply to the next key or click.
private struct KeyBar: View {
    let session: RemoteSession
    @ObservedObject var state: ViewerState

    var body: some View {
        HStack(spacing: 8) {
            key("esc", KeyCodes.escape)
            key("tab", KeyCodes.tab)
            modifier("⇧", .shift)
            modifier("⌃", .control)
            modifier("⌥", .option)
            modifier("⌘", .command)
            Spacer(minLength: 0)
            key(systemImage: "arrow.left", KeyCodes.leftArrow)
            key(systemImage: "arrow.down", KeyCodes.downArrow)
            key(systemImage: "arrow.up", KeyCodes.upArrow)
            key(systemImage: "arrow.right", KeyCodes.rightArrow)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func key(_ title: String, _ keyCode: UInt16) -> some View {
        Button { tap(keyCode) } label: { Text(title).frame(minWidth: 36) }
            .buttonStyle(.bordered)
    }

    private func key(systemImage: String, _ keyCode: UInt16) -> some View {
        Button { tap(keyCode) } label: { Image(systemName: systemImage).frame(minWidth: 28) }
            .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func modifier(_ title: String, _ modifier: Modifiers) -> some View {
        let isOn = state.stickyModifiers.contains(modifier)
        let button = Button {
            state.stickyModifiers.formSymmetricDifference(modifier)
        } label: {
            Text(title).frame(minWidth: 28)
        }
        if isOn {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func tap(_ keyCode: UInt16) {
        session.send(.key(keyCode, down: true, mods: state.stickyModifiers))
        session.send(.key(keyCode, down: false, mods: state.stickyModifiers))
        state.stickyModifiers = []
    }
}
