import SwiftUI

@main
struct SunoApp: App {
    init() { applyAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }

    func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = AppTheme.bgUI
        nav.titleTextAttributes = [.foregroundColor: AppTheme.textUI]
        nav.largeTitleTextAttributes = [.foregroundColor: AppTheme.textUI]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(hex: "#FF6B3D")

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = AppTheme.bgUI
        tab.stackedLayoutAppearance.selected.iconColor = UIColor(hex: "#FF6B3D")
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(hex: "#FF6B3D")]
        tab.stackedLayoutAppearance.normal.iconColor = AppTheme.textSecondaryUI
        tab.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: AppTheme.textSecondaryUI]
        UITabBar.appearance().standardAppearance = tab
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tab
        }
        UITabBar.appearance().tintColor = UIColor(hex: "#FF6B3D")
    }
}
