import Foundation
import Network
import UIKit

struct ConnectFailure: Error {
    var message: String
    var isAuthentication: Bool
}

/// A live connection to one Mac.
@MainActor
final class RemoteSession: ObservableObject {
    @Published private(set) var hello: ServerHello?
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var thumbnails: [UInt32: UIImage] = [:]
    @Published private(set) var isLoadingWindows = false
    @Published private(set) var isLocked = false
    @Published private(set) var isUnlocking = false
    @Published private(set) var unlockMessage: String?
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var appIcons: [UInt32: UIImage] = [:]
    private var requestedAppIcons = Set<UInt32>()
    /// Menu listings received so far, keyed by their path in the Mac app's menu bar.
    @Published private(set) var menus: [[Int]: MenuListing] = [:]

    let renderer = VideoRenderer()
    /// The connection dropped after it was established.
    var onClosed: ((String?) -> Void)?
    /// The server refused a request or ended the stream; the connection is still up.
    /// The message is nil when the app already shows the reason some other way.
    var onError: ((String?) -> Void)?

    private var conn: OGConnection?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var isClosed = false

    func connect(host: String, port: UInt16, password: String) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            throw ConnectFailure(message: "The address isn't valid.", isAuthentication: false)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: OGConnection.parameters(password: password))
        let conn = OGConnection(connection)
        self.conn = conn

        let renderer = self.renderer
        conn.onMessage = { [weak self] type, payload in
            if type == .videoFrame {
                renderer.handle(payload)
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
        renderer.onNeedsKeyframe = { [weak self] in self?.requestKeyframe() }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            conn.start()
            Task {
                try? await Task.sleep(for: .seconds(10))
                self.failConnect(ConnectFailure(message: "The Mac didn't respond. Check the address and that OGConnect Server is running.",
                                                isAuthentication: false))
            }
        }
    }

    func disconnect() {
        isClosed = true
        conn?.cancel()
    }

    // MARK: - Requests

    func refreshWindows() {
        isLoadingWindows = true
        conn?.send(.listWindows)
    }

    func requestApps() {
        conn?.send(.listApps)
    }

    func requestAppIcon(_ id: UInt32) {
        guard requestedAppIcons.insert(id).inserted else { return }
        conn?.send(.appIconRequest, json: AppRequest(id: id))
    }

    /// Launches the app on the Mac, then reloads the window list once it has had time to open.
    func launchApp(_ id: UInt32) {
        conn?.send(.launchApp, json: AppRequest(id: id))
        for delay in [1.5, 4.0] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                refreshWindows()
            }
        }
    }

    func resetMenus() {
        menus = [:]
    }

    func requestMenu(path: [Int]) {
        conn?.send(.menuRequest, json: MenuRequest(path: path))
    }

    func performMenu(path: [Int], title: String) {
        conn?.send(.menuAction, json: MenuAction(path: path, title: title))
    }

    /// Asks the server to type the Mac account password into its lock screen.
    func unlock(password: String) {
        isUnlocking = true
        unlockMessage = nil
        conn?.send(.unlock, json: UnlockRequest(password: password))
    }

    private func setLocked(_ locked: Bool) {
        let wasLocked = isLocked
        isLocked = locked
        if locked {
            windows = []
        } else if wasLocked {
            refreshWindows()
        }
    }

    func startStream(_ window: WindowInfo) {
        renderer.reset()
        conn?.send(.startStream, json: StartStream(windowID: window.id))
    }

    func stopStream() {
        conn?.send(.stopStream)
    }

    func requestKeyframe() {
        conn?.send(.requestKeyframe)
    }

    func send(_ event: InputEvent) {
        conn?.send(.input, json: event)
    }

    // MARK: - Incoming

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            continuation?.resume()
            continuation = nil
        case .waiting(let error), .failed(let error):
            if isReady {
                close(error.localizedDescription)
            } else {
                failConnect(Self.failure(for: error))
            }
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func failConnect(_ failure: ConnectFailure) {
        guard let continuation else { return }
        self.continuation = nil
        isClosed = true
        conn?.cancel()
        continuation.resume(throwing: failure)
    }

    private func close(_ message: String?) {
        guard isReady, !isClosed else { return }
        isClosed = true
        conn?.cancel()
        onClosed?(message)
    }

    private func handle(_ type: OGMessageType, _ payload: Data) {
        let decoder = JSONDecoder()
        switch type {
        case .hello:
            hello = try? decoder.decode(ServerHello.self, from: payload)
            if let locked = hello?.isLocked { setLocked(locked) }
        case .appList:
            guard let list = try? decoder.decode([AppInfo].self, from: payload) else { return }
            // Ids are positions in the server's list, so icons from an older list no longer apply.
            if list.map(\.name) != apps.map(\.name) {
                appIcons = [:]
                requestedAppIcons = []
            }
            apps = list
        case .appIcon:
            guard let (id, png) = ThumbnailPayload.decode(payload), let image = UIImage(data: png) else { return }
            appIcons[id] = image
        case .menu:
            guard let listing = try? decoder.decode(MenuListing.self, from: payload) else { return }
            menus[listing.path] = listing
        case .lockState:
            guard let state = try? decoder.decode(LockState.self, from: payload) else { return }
            isUnlocking = false
            unlockMessage = state.message
            setLocked(state.isLocked)
        case .windowList:
            isLoadingWindows = false
            guard let list = try? decoder.decode([WindowInfo].self, from: payload) else { return }
            windows = list
            let ids = Set(list.map(\.id))
            thumbnails = thumbnails.filter { ids.contains($0.key) }
            for window in list {
                conn?.send(.thumbnailRequest, json: ThumbnailRequest(windowID: window.id, maxDimension: 640))
            }
        case .thumbnail:
            guard let (id, jpeg) = ThumbnailPayload.decode(payload), let image = UIImage(data: jpeg) else { return }
            thumbnails[id] = image
        case .streamEnded, .error:
            guard let text = try? decoder.decode(TextMessage.self, from: payload) else { return }
            // When the Mac is locked the window list explains it and offers to unlock.
            onError?(isLocked ? nil : text.message)
        default:
            break
        }
    }

    private static func failure(for error: NWError) -> ConnectFailure {
        switch error {
        case .tls:
            // The password is the TLS key, so a failed handshake means it didn't match.
            return ConnectFailure(message: "Incorrect password.", isAuthentication: true)
        case .posix(let code) where code == .ECONNREFUSED:
            return ConnectFailure(message: "The Mac refused the connection. Check that OGConnect Server is running and the port matches.",
                                  isAuthentication: false)
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .ENETUNREACH || code == .EHOSTDOWN:
            return ConnectFailure(message: "Couldn't reach the Mac. Check the address and that both devices are on the same network.",
                                  isAuthentication: false)
        default:
            return ConnectFailure(message: error.localizedDescription, isAuthentication: false)
        }
    }
}
