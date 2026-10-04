import SwiftUI

@main
struct OGConnectServerApp: App {
    @StateObject private var server = ServerController()

    var body: some Scene {
        MenuBarExtra {
            StatusView()
                .environmentObject(server)
        } label: {
            Image(systemName: server.clients.isEmpty ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
