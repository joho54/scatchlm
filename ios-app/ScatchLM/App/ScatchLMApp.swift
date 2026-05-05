import SwiftUI

@main
struct ScatchLMApp: App {
    @State private var auth = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isLoading {
                    ProgressView("Loading...")
                } else if auth.isAuthenticated {
                    NavigationStack {
                        HomeView()
                    }
                } else {
                    LoginView()
                }
            }
            .task {
                await auth.initialize()
            }
        }
    }
}
