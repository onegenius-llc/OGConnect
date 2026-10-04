import Foundation

struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = OGProtocol.defaultPort

    var displayName: String { name.isEmpty ? host : name }
}

enum Route: Hashable {
    case windows
    case viewer(WindowInfo)
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    var connection: SavedConnection
    var message: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []
    @Published var path: [Route] = []
    @Published private(set) var session: RemoteSession?
    @Published private(set) var activeConnection: SavedConnection?
    @Published private(set) var connectingID: UUID?
    @Published var passwordPrompt: PasswordPrompt?
    @Published var alertMessage: String?

    private static let storageKey = "connections"
    private static let keychainService = "com.onegenius.ogconnect"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            connections = saved
        }
    }

    // MARK: - Saved connections

    func save(_ connection: SavedConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            // A password saved for one Mac shouldn't be offered to another.
            if connections[index].host != connection.host || connections[index].port != connection.port {
                forgetPassword(for: connection)
            }
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    func delete(_ connection: SavedConnection) {
        forgetPassword(for: connection)
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    func hasSavedPassword(for connection: SavedConnection) -> Bool {
        Keychain.get(service: Self.keychainService, account: connection.id.uuidString) != nil
    }

    func forgetPassword(for connection: SavedConnection) {
        Keychain.delete(service: Self.keychainService, account: connection.id.uuidString)
        objectWillChange.send()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Connecting

    func open(_ connection: SavedConnection) {
        guard connectingID == nil else { return }
        if let password = Keychain.get(service: Self.keychainService, account: connection.id.uuidString) {
            connect(connection, password: password, remember: true)
        } else {
            passwordPrompt = PasswordPrompt(connection: connection)
        }
    }

    func connect(_ connection: SavedConnection, password: String, remember: Bool) {
        guard connectingID == nil else { return }
        connectingID = connection.id

        let session = RemoteSession()
        session.onClosed = { [weak self, weak session] message in
            self?.sessionClosed(session, message: message)
        }
        session.onError = { [weak self, weak session] message in
            self?.sessionFailed(session, message: message)
        }

        Task {
            defer { connectingID = nil }
            do {
                try await session.connect(host: connection.host, port: connection.port, password: password)
                if remember {
                    Keychain.set(password, service: Self.keychainService, account: connection.id.uuidString)
                } else {
                    forgetPassword(for: connection)
                }
                self.session = session
                activeConnection = connection
                path = [.windows]
            } catch let failure as ConnectFailure {
                if failure.isAuthentication {
                    forgetPassword(for: connection)
                    passwordPrompt = PasswordPrompt(connection: connection, message: failure.message)
                } else {
                    alertMessage = failure.message
                }
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        guard let session else { return }
        self.session = nil
        activeConnection = nil
        session.onClosed = nil
        session.disconnect()
    }

    private func sessionClosed(_ closed: RemoteSession?, message: String?) {
        guard let closed, closed === session else { return }
        session = nil
        activeConnection = nil
        path = []
        alertMessage = message ?? "The connection to the Mac was lost."
    }

    /// The server refused a request or the stream ended; the connection itself is still good.
    private func sessionFailed(_ failed: RemoteSession?, message: String?) {
        guard let failed, failed === session else { return }
        if path.count > 1 { path = [.windows] }
        if let message { alertMessage = message }
    }
}
