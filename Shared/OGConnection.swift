import CommonCrypto
import Foundation
import Network

/// Framed message transport over a TLS-PSK connection. Both ends derive the pre-shared key from the
/// password, so a completed handshake is the login and everything after it is encrypted.
final class OGConnection: @unchecked Sendable {
    let connection: NWConnection
    /// Both callbacks are invoked on the connection's private queue.
    var onMessage: ((OGMessageType, Data) -> Void)?
    var onState: ((NWConnection.State) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = 0

    /// Number of sends handed to the network stack that haven't been written yet.
    var pendingSends: Int { lock.withLock { pending } }

    init(_ connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.onegenius.ogconnect.connection")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onState?(state)
            if case .ready = state { self.receiveHeader() }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ type: OGMessageType, _ payload: Data = Data()) {
        var frame = Data(capacity: payload.count + 5)
        withUnsafeBytes(of: UInt32(payload.count + 1).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        lock.withLock { pending += 1 }
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.pending -= 1 }
        })
    }

    func send<T: Encodable>(_ type: OGMessageType, json value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(type, data)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else {
                self.connection.cancel()
                return
            }
            let length = data.reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= OGProtocol.maxMessageSize else {
                self.connection.cancel()
                return
            }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else {
                self.connection.cancel()
                return
            }
            // Unknown types are skipped so older builds tolerate newer peers.
            if let type = OGMessageType(rawValue: data[data.startIndex]) {
                self.onMessage?(type, data.dropFirst())
            }
            self.receiveHeader()
        }
    }

    // MARK: - TLS

    private static let pskIdentity = "OGConnect"

    static func parameters(password: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = derivedKey(password: password)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                keyData as __DispatchData,
                                                identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 8
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// PBKDF2 stretches the password so a captured handshake is expensive to brute-force offline.
    private static func derivedKey(password: String) -> Data {
        let salt = Array("com.onegenius.ogconnect.psk.v1".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password, password.utf8.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 100_000,
                                 &key, key.count)
        return Data(key)
    }
}
