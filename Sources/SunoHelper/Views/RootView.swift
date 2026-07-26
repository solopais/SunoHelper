import SwiftUI

struct RootView: View {
    @StateObject private var session = SunoSession.shared

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            if session.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            GenerateView()
                .tabItem { Label("创作", systemImage: "music.note") }

            LibraryView()
                .tabItem { Label("音乐库", systemImage: "music.note.list") }

            SettingsView()
                .tabItem { Label("我的", systemImage: "person.circle") }
        }
        .accentColor(AppTheme.accent)
    }
}
