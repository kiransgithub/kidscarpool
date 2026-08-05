import SwiftUI

@main
struct SchoolCarpoolApp: App {
    @State private var store = CarpoolStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(nil)
        }
    }
}
