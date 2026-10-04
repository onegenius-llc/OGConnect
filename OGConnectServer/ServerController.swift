import Foundation
import Network

@MainActor
final class ServerController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    struct Client: Identifiable {
        var id: UUID
        var remote: String
        var streamingTitle: String?
    }

    struct Address: Identifiable {
        var interface: String
        var address: String
        var id: String { interface + address }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var clients: [Client] = []
    @Published private(set) var addresses: [Address] = []
    @Published private(set) var password: String
    @Published private(set) var port: UInt16
    @Published private(set) var canCapture = Permissions.screenRecording
    @Published private(set) var canControl = Permissions.accessibility
    @Published private(set) var keepAwake: PowerManager.Mode

    private let power = PowerManager()
    private var lockObservers: [NSObjectProtocol] = []
    private var listener: NWListener?
    private var retry: DispatchWorkItem?
    private var sessions: [UUID: ClientSession] = [:]
    /// Set when the password comes from the environment, so it's never written to the keychain.
    private var isEphemeral = false

    private static let keychainService = "com.onegenius.ogconnect.server"
    private static let keychainAccount = "password"
    private static let portKey = "port"
    private static let keepAwakeKey = "keepAwake"

    init() {
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = UInt16(exactly: storedPort).flatMap { $0 == 0 ? nil : $0 } ?? OGProtocol.defaultPort
        password = ""
        keepAwake = UserDefaults.standard.string(forKey: Self.keepAwakeKey).flatMap(PowerManager.Mode.init) ?? .whileConnected

        #if DEBUG
        // Lets a development build run alongside the installed one without touching its settings.
        let environment = ProcessInfo.processInfo.environment
        if let testPassword = environment["OGCONNECT_TEST_PASSWORD"], !testPassword.isEmpty {
            password = testPassword
            isEphemeral = true
            if let testPort = environment["OGCONNECT_TEST_PORT"].flatMap(UInt16.init) {
                port = testPort
            }
        }
        #endif

        if !isEphemeral {
            if let stored = Keychain.get(service: Self.keychainService, account: Self.keychainAccount), !stored.isEmpty {
                password = stored
            } else {
                password = Self.randomPassword()
                Keychain.set(password, service: Self.keychainService, account: Self.keychainAccount)
            }
        }

        if !canCapture { Permissions.requestScreenRecording(openSettings: false) }
        if !canControl { Permissions.requestAccessibility(openSettings: false) }

        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessions.values.forEach { $0.lockStateChanged(locked) }
                }
            })
        }

        refresh()
        updatePower()
        start()
    }

    func setKeepAwake(_ mode: PowerManager.Mode) {
        keepAwake = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.keepAwakeKey)
        updatePower()
    }

    private func updatePower() {
        switch keepAwake {
        case .never: power.setHoldingAwake(false)
        case .whileConnected: power.setHoldingAwake(!clients.isEmpty)
        case .always: power.setHoldingAwake(true)
        }
    }

    /// Re-reads things that change behind our back: permissions and network addresses.
    func refresh() {
        let capture = Permissions.screenRecording
        let control = Permissions.accessibility
        if capture != canCapture { canCapture = capture }
        if control != canControl { canControl = control }
        addresses = Self.localAddresses()
    }

    func update(password newPassword: String, port newPort: UInt16) {
        guard !newPassword.isEmpty, newPort != 0 else { return }
        password = newPassword
        port = newPort
        if !isEphemeral {
            Keychain.set(newPassword, service: Self.keychainService, account: Self.keychainAccount)
            UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        }
        // Existing clients were authenticated with the old password.
        sessions.values.forEach { $0.close() }
        start()
    }

    private func start() {
        listener?.cancel()
        listener = nil
        retry?.cancel()
        // While retrying, keep showing why it failed rather than flickering through "stopped".
        if case .failed = status {} else { status = .stopped }

        do {
            let listener = try NWListener(using: OGConnection.parameters(password: password),
                                          on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready: self.status = .listening
                        case .failed(let error): self.listenerFailed(error.localizedDescription)
                        case .waiting(let error): self.listenerFailed(error.localizedDescription)
                        default: break
                        }
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            listenerFailed(error.localizedDescription)
        }
    }

    /// Usually the port is held by another copy of the server. Keep trying, so this one takes
    /// over as soon as the other quits instead of sitting dead until someone restarts it.
    private func listenerFailed(_ message: String) {
        status = .failed(message)
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let session = ClientSession(connection: connection)
        sessions[session.id] = session
        session.onChange = { [weak self] in self?.publishClients() }
        session.onClosed = { [weak self, id = session.id] in
            self?.sessions[id] = nil
            self?.publishClients()
        }
    }

    private func publishClients() {
        // Connections that never finish the handshake (wrong password) aren't clients.
        clients = sessions.values
            .filter(\.isReady)
            .map { Client(id: $0.id, remote: $0.remote, streamingTitle: $0.streamingTitle) }
            .sorted { $0.remote < $1.remote }
        updatePower()
    }

    private static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    private static func localAddresses() -> [Address] {
        var result: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }

        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Address(interface: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
        }
        return result
    }
}
