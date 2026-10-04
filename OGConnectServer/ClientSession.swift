import Foundation
import Network
import ScreenCaptureKit

/// Applies input events on the connection's queue so they never wait behind the main thread.
private final class InputRouter {
    private let injector = InputInjector()
    private let lock = NSLock()
    private var _target: WindowStreamer?

    var target: WindowStreamer? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }

    func handle(_ payload: Data) {
        guard let target, let event = try? JSONDecoder().decode(InputEvent.self, from: payload) else { return }
        injector.handle(event, target: target)
    }
}

/// One connected iPad.
@MainActor
final class ClientSession {
    let id = UUID()
    let remote: String
    private(set) var isReady = false
    private(set) var streamingTitle: String?
    var onChange: (() -> Void)?
    var onClosed: (() -> Void)?

    private let conn: OGConnection
    private let router = InputRouter()
    private var content: SCShareableContent?
    private var streamer: WindowStreamer?
    private var streamGeneration = 0
    private var closed = false
    private var isUnlocking = false
    private var apps: [AppCatalog.Entry] = []

    init(connection: NWConnection) {
        if case let .hostPort(host, _) = connection.endpoint {
            remote = "\(host)"
        } else {
            remote = "\(connection.endpoint)"
        }
        conn = OGConnection(connection)

        let router = self.router
        conn.onMessage = { [weak self] type, payload in
            if type == .input {
                router.handle(payload)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(type, payload) }
            }
        }
        conn.onState = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(state) }
            }
        }
        conn.start()
    }

    func close() {
        guard !closed else { return }
        closed = true
        stopStream()
        conn.cancel()
        onClosed?()
    }

    func lockStateChanged(_ locked: Bool) {
        guard isReady else { return }
        conn.send(.lockState, json: LockState(isLocked: locked))
        // A locked screen hides every window; a running stream would just go black.
        if locked, streamer != nil {
            stopStream()
            conn.send(.streamEnded, json: TextMessage(message: PowerManager.lockedMessage))
        }
    }

    private func unlock(_ request: UnlockRequest) {
        guard PowerManager.isScreenLocked else {
            conn.send(.lockState, json: LockState(isLocked: false))
            return
        }
        guard Permissions.accessibility else {
            conn.send(.lockState, json: LockState(isLocked: true,
                                                  message: "OGConnect Server needs Accessibility permission on the Mac before it can unlock it."))
            return
        }
        guard !isUnlocking else { return }
        isUnlocking = true

        let keystrokes = ScreenUnlocker.keystrokes(for: request.password)
        DispatchQueue.global(qos: .userInitiated).async {
            let unlocked = ScreenUnlocker.perform(keystrokes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isUnlocking = false
                    self.conn.send(.lockState, json: LockState(isLocked: !unlocked,
                                                               message: unlocked ? nil : "The Mac is still locked. Check the password and try again."))
                }
            }
        }
    }

    private func sendHello() {
        conn.send(.hello, json: ServerHello(version: OGProtocol.version,
                                            name: Host.current().localizedName ?? "Mac",
                                            canCapture: Permissions.screenRecording,
                                            canControl: Permissions.accessibility,
                                            isLocked: PowerManager.isScreenLocked))
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            PowerManager.wakeDisplay()
            sendHello()
            onChange?()
        case .failed, .cancelled:
            close()
        default:
            break
        }
    }

    private func handle(_ type: OGMessageType, _ payload: Data) {
        switch type {
        case .listWindows:
            listWindows()
        case .thumbnailRequest:
            guard let request = try? JSONDecoder().decode(ThumbnailRequest.self, from: payload) else { return }
            sendThumbnail(request)
        case .startStream:
            guard let request = try? JSONDecoder().decode(StartStream.self, from: payload) else { return }
            startStream(request)
        case .stopStream:
            stopStream()
        case .requestKeyframe:
            streamer?.requestKeyframe()
        case .unlock:
            guard let request = try? JSONDecoder().decode(UnlockRequest.self, from: payload) else { return }
            unlock(request)
        case .listApps:
            listApps()
        case .appIconRequest:
            guard let request = try? JSONDecoder().decode(AppRequest.self, from: payload),
                  apps.indices.contains(Int(request.id)),
                  let png = AppCatalog.icon(for: apps[Int(request.id)].url) else { return }
            conn.send(.appIcon, ThumbnailPayload.encode(windowID: request.id, jpeg: png))
        case .launchApp:
            guard let request = try? JSONDecoder().decode(AppRequest.self, from: payload),
                  apps.indices.contains(Int(request.id)) else { return }
            PowerManager.wakeDisplay()
            AppCatalog.launch(apps[Int(request.id)].url)
        case .menuRequest:
            guard let request = try? JSONDecoder().decode(MenuRequest.self, from: payload) else { return }
            sendMenu(request)
        case .menuAction:
            guard let action = try? JSONDecoder().decode(MenuAction.self, from: payload) else { return }
            performMenu(action)
        default:
            break
        }
    }

    private func listApps() {
        apps = AppCatalog.scan()
        let running = AppCatalog.runningAppURLs()
        let list = apps.enumerated().map { index, app in
            AppInfo(id: UInt32(index), name: app.name, isRunning: running.contains(app.url.resolvingSymlinksInPath()))
        }
        conn.send(.appList, json: list)
    }

    private func sendMenu(_ request: MenuRequest) {
        let conn = self.conn
        guard let pid = streamer?.pid else {
            conn.send(.menu, json: MenuListing(path: request.path, items: [], error: "No window is being shared."))
            return
        }
        guard Permissions.accessibility else {
            conn.send(.menu, json: MenuListing(path: request.path, items: [],
                                               error: "OGConnect Server needs Accessibility permission on the Mac to read menus."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let items = MenuReader.items(pid: pid, path: request.path) {
                conn.send(.menu, json: MenuListing(path: request.path, items: items))
            } else {
                conn.send(.menu, json: MenuListing(path: request.path, items: [], error: "This app's menus couldn't be read."))
            }
        }
    }

    private func performMenu(_ action: MenuAction) {
        guard let streamer else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Menu commands act on the app's front window, so make sure that's the one being viewed.
            streamer.bringToFrontIfNeeded()
            _ = MenuReader.press(pid: streamer.pid, path: action.path, title: action.title)
        }
    }

    private func listWindows() {
        guard !PowerManager.isScreenLocked else {
            conn.send(.windowList, json: [WindowInfo]())
            conn.send(.lockState, json: LockState(isLocked: true))
            return
        }
        Task {
            do {
                let content = try await WindowCatalog.content()
                self.content = content
                conn.send(.windowList, json: WindowCatalog.windows(in: content))
            } catch {
                conn.send(.windowList, json: [WindowInfo]())
                conn.send(.error, json: TextMessage(message: Self.describe(error)))
            }
        }
    }

    private func sendThumbnail(_ request: ThumbnailRequest) {
        guard let content, let window = content.windows.first(where: { $0.windowID == request.windowID }) else { return }
        Task {
            guard let jpeg = await WindowCatalog.thumbnail(of: window, in: content, maxDimension: min(request.maxDimension, 1024)) else { return }
            conn.send(.thumbnail, ThumbnailPayload.encode(windowID: request.windowID, jpeg: jpeg))
        }
    }

    private func startStream(_ request: StartStream) {
        stopStream()
        let generation = streamGeneration
        PowerManager.wakeDisplay()
        // Permissions can be granted while connected; let the client know where things stand now.
        sendHello()
        Task {
            do {
                guard !PowerManager.isScreenLocked else {
                    throw StreamError(PowerManager.lockedMessage)
                }
                let content = try await WindowCatalog.content()
                self.content = content
                guard let window = content.windows.first(where: { $0.windowID == request.windowID }),
                      let info = WindowCatalog.windows(in: content).first(where: { $0.id == request.windowID }) else {
                    throw StreamError("That window is no longer available.")
                }

                let streamer = try WindowStreamer(window: window, info: info, content: content)
                let conn = self.conn
                streamer.onPacket = { conn.send(.videoFrame, $0) }
                streamer.isCongested = { conn.pendingSends > 4 }
                streamer.onEnded = { [weak self, weak streamer] reason in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.streamEnded(streamer, reason: reason) }
                    }
                }
                try await streamer.start()

                // A newer start/stop arrived while this one was starting up.
                guard generation == streamGeneration, !closed else {
                    streamer.stop()
                    return
                }
                self.streamer = streamer
                router.target = streamer
                streamingTitle = "\(info.appName) — \(info.title)"
                conn.send(.streamStarted, json: info)
                onChange?()
            } catch {
                guard generation == streamGeneration else { return }
                conn.send(.error, json: TextMessage(message: Self.describe(error)))
            }
        }
    }

    private func stopStream() {
        streamGeneration += 1
        router.target = nil
        streamer?.stop()
        streamer = nil
        if streamingTitle != nil {
            streamingTitle = nil
            onChange?()
        }
    }

    private func streamEnded(_ ended: WindowStreamer?, reason: String) {
        guard let ended, ended === streamer else { return }
        stopStream()
        conn.send(.streamEnded, json: TextMessage(message: reason))
    }

    private static func describe(_ error: Error) -> String {
        if error is StreamError {
            return error.localizedDescription
        }
        if !Permissions.screenRecording {
            return "OGConnect Server doesn't have Screen Recording permission on the Mac. Grant it in System Settings › Privacy & Security, then relaunch the server."
        }
        return error.localizedDescription
    }
}
