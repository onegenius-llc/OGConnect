import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var server: ServerController
    @State private var passwordDraft = ""
    @State private var portDraft = ""
    @State private var showsPassword = false

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            addresses
            credentials
            Divider()
            keepAwake
            Divider()
            permissions
            Divider()
            clients
            Divider()
            HStack {
                Spacer()
                Button("Quit OGConnect Server") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            passwordDraft = server.password
            portDraft = String(server.port)
            server.refresh()
        }
        .onReceive(refreshTimer) { _ in server.refresh() }
    }

    private var header: some View {
        HStack {
            Text("OGConnect Server").font(.headline)
            Spacer()
            switch server.status {
            case .listening:
                Label("Listening", systemImage: "circle.fill").foregroundStyle(.green)
            case .stopped:
                Label("Stopped", systemImage: "circle.fill").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.callout)
    }

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This Mac's address").font(.subheadline).foregroundStyle(.secondary)
            if server.addresses.isEmpty {
                Text("Not connected to a network")
            }
            ForEach(server.addresses) { address in
                HStack {
                    Text(address.address).font(.body.monospaced()).textSelection(.enabled)
                    Text(address.interface).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var credentials: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Password")
                HStack {
                    Group {
                        if showsPassword {
                            TextField("Password", text: $passwordDraft)
                        } else {
                            SecureField("Password", text: $passwordDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        showsPassword.toggle()
                    } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
            GridRow {
                Text("Port")
                HStack {
                    TextField("Port", text: $portDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                    Button("Apply") {
                        if let port = draftPort { server.update(password: passwordDraft, port: port) }
                    }
                    .disabled(!hasValidChanges)
                }
            }
        }
    }

    private var keepAwake: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Keep Mac awake", selection: Binding(get: { server.keepAwake }, set: { server.setKeepAwake($0) })) {
                ForEach(PowerManager.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text("macOS locks the screen when the display sleeps, which hides every window from the iPad. A locked Mac has to be unlocked at the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draftPort: UInt16? {
        UInt16(portDraft).flatMap { $0 == 0 ? nil : $0 }
    }

    private var hasValidChanges: Bool {
        guard let port = draftPort, !passwordDraft.isEmpty else { return false }
        return port != server.port || passwordDraft != server.password
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.subheadline).foregroundStyle(.secondary)
            permissionRow("Screen Recording", detail: "to show windows", granted: server.canCapture) {
                Permissions.requestScreenRecording(openSettings: true)
            }
            permissionRow("Accessibility", detail: "to control mouse and keyboard", granted: server.canControl) {
                Permissions.requestAccessibility(openSettings: true)
            }
            if !server.canCapture {
                Text("Relaunch OGConnect Server after granting Screen Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ name: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: request)
            }
        }
    }

    private var clients: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connected").font(.subheadline).foregroundStyle(.secondary)
            if server.clients.isEmpty {
                Text("No devices connected").foregroundStyle(.secondary)
            }
            ForEach(server.clients) { client in
                VStack(alignment: .leading) {
                    Text(client.remote)
                    Text(client.streamingTitle ?? "Browsing windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
