import SwiftUI

/// The main menu: saved Macs, and the root of navigation into a connection.
struct ConnectionListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: SavedConnection?

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                ForEach(model.connections) { connection in
                    row(connection)
                }
            }
            .overlay {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "macbook.and.ipad")
                    } description: {
                        Text("Add the address of a Mac running OGConnect Server.")
                    } actions: {
                        Button("Add Connection") { editing = SavedConnection(name: "", host: "") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("OGConnect")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = SavedConnection(name: "", host: "")
                    } label: {
                        Label("Add Connection", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                if let session = model.session {
                    switch route {
                    case .windows:
                        WindowListView(session: session, title: model.activeConnection?.displayName ?? "Windows")
                    case .viewer(let window):
                        ViewerView(session: session, window: window)
                    }
                }
            }
        }
        .onChange(of: model.path) { _, path in
            if path.isEmpty { model.disconnect() }
        }
        .sheet(item: $editing) { connection in
            ConnectionEditView(connection: connection)
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            // A retry after a wrong password is a new prompt and should start empty.
            PasswordPromptView(prompt: prompt)
                .id(prompt.id)
        }
        .alert("OGConnect", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    private func row(_ connection: SavedConnection) -> some View {
        Button {
            model.open(connection)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                if model.connectingID == connection.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .disabled(model.connectingID != nil)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { model.delete(connection) }
            Button("Edit") { editing = connection }
        }
        .contextMenu {
            Button {
                editing = connection
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if model.hasSavedPassword(for: connection) {
                Button {
                    model.forgetPassword(for: connection)
                } label: {
                    Label("Forget Password", systemImage: "key.slash")
                }
            }
            Button(role: .destructive) {
                model.delete(connection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct ConnectionEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var connection: SavedConnection
    @State private var portText = ""

    private var port: UInt16? {
        UInt16(portText).flatMap { $0 == 0 ? nil : $0 }
    }

    private var host: String {
        connection.host.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $connection.name)
                    TextField("IP address or host name", text: $connection.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("The address and port are shown in the OGConnect Server menu on the Mac.")
                }
            }
            .navigationTitle(model.connections.contains { $0.id == connection.id } ? "Edit Connection" : "New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let port else { return }
                        connection.host = host
                        connection.name = connection.name.trimmingCharacters(in: .whitespaces)
                        connection.port = port
                        model.save(connection)
                        dismiss()
                    }
                    .disabled(host.isEmpty || port == nil)
                }
            }
            .onAppear { portText = String(connection.port) }
        }
    }
}

struct PasswordPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prompt: PasswordPrompt
    @State private var password = ""
    @State private var remember = true
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit(connect)
                    Toggle("Remember password", isOn: $remember)
                } header: {
                    if let message = prompt.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textCase(nil)
                    }
                } footer: {
                    Text("The password is shown in the OGConnect Server menu on the Mac.")
                }
            }
            .navigationTitle(prompt.connection.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .disabled(password.isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func connect() {
        guard !password.isEmpty else { return }
        dismiss()
        model.connect(prompt.connection, password: password, remember: remember)
    }
}
