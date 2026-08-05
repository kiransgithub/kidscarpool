import SwiftUI

// MARK: - KCP visual system

enum KCPTheme {
    static let navy = Color(red: 0.035, green: 0.15, blue: 0.30)
    static let blue = Color(red: 0.20, green: 0.38, blue: 0.96)
    static let violet = Color(red: 0.43, green: 0.31, blue: 0.96)
    static let cyan = Color(red: 0.12, green: 0.70, blue: 0.92)
    static let green = Color(red: 0.20, green: 0.70, blue: 0.40)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.15)
    static let red = Color(red: 0.95, green: 0.30, blue: 0.28)

    static let heroGradient = LinearGradient(
        colors: [navy, blue, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let actionGradient = LinearGradient(
        colors: [blue, violet],
        startPoint: .leading,
        endPoint: .trailing
    )

    static func parentColor(_ name: String) -> Color {
        switch name {
        case "Kiran": return blue
        case "Mohan": return green
        case "Pavan": return orange
        case "Santosh": return violet
        default: return cyan
        }
    }
}

struct KCPCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: KCPTheme.navy.opacity(0.08), radius: 12, y: 6)
    }
}

extension View {
    func kcpCard() -> some View { modifier(KCPCardModifier()) }
}

struct RootView: View {
    @Environment(CarpoolStore.self) private var store

    var body: some View {
        Group {
            if store.isSignedIn {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .tint(KCPTheme.blue)
        .task { await store.bootstrap() }
        .alert("Kidscarpool", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { DashboardView() }
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { GroupsView() }
                .tabItem { Label("Groups", systemImage: "person.3.sequence.fill") }

            NavigationStack { ScheduleView() }
                .tabItem { Label("Schedule", systemImage: "calendar") }

            NavigationStack { VolunteerBoardView() }
                .tabItem { Label("Volunteers", systemImage: "person.3.fill") }

            NavigationStack { FairnessView() }
                .tabItem { Label("Leaderboard", systemImage: "trophy.fill") }

            NavigationStack { AlertsView() }
                .tabItem { Label("Alerts", systemImage: "bell.fill") }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    }
}
