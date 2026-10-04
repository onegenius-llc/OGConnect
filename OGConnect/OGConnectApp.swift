import SwiftUI

@main
struct OGConnectApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(model)
        }
    }
}
