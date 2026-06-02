import SwiftUI

/// A top-level destination in the app.
///
/// On macOS these are sidebar rows in a `NavigationSplitView`; on iOS the
/// review/settings subset is surfaced as a `TabView`. The server surfaces
/// (`status`, `requests`) are macOS-only "Pro" features.
enum NavigationItem: String, CaseIterable, Identifiable {
    case review
    case status
    case requests
    case settings

    var id: Self { self }

    init?(screenshotName: String?) {
        switch screenshotName?.lowercased() {
        case "status": self = .status
        case "review": self = .review
        case "settings": self = .settings
        case "requests": self = .requests
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .review: "Review"
        case .status: "Server"
        case .requests: "Requests"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .review: "checklist"
        case .status: "server.rack"
        case .requests: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }

    /// `⌘1…⌘4`, following sidebar order (Review first).
    var shortcut: KeyEquivalent {
        switch self {
        case .review: "1"
        case .status: "2"
        case .requests: "3"
        case .settings: "4"
        }
    }

    /// Destinations exposed on iOS (no embedded server there).
    static let iOSItems: [NavigationItem] = [.review, .settings]
}

struct ContentView: View {
    @EnvironmentObject var host: ServerHost
    @State private var selection: NavigationItem = NavigationItem(screenshotName: DemoMode.screenshotTab) ?? .review

    var body: some View {
        platformBody
            .tint(Theme.Colors.accent)
            .focusedSceneValue(\.selectedNavigationItem, $selection)
    }

    #if os(macOS)
    private var platformBody: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    row(.review)
                }
                Section("Pro") {
                    row(.status)
                    row(.requests)
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .listStyle(.sidebar)
            .navigationTitle("Telephone Booth")
        } detail: {
            detail(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Theme.Colors.textPrimary)
                .background(ThemedWindowBackground())
                .navigationTitle(selection.title)
        }
    }

    private func row(_ item: NavigationItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }

    /// Bridges the non-optional app selection to the optional `List` binding,
    /// keeping a destination always selected.
    private var sidebarSelection: Binding<NavigationItem?> {
        Binding(
            get: { selection },
            set: { selection = $0 ?? .review }
        )
    }
    #else
    private var platformBody: some View {
        TabView(selection: iOSSelection) {
            ForEach(NavigationItem.iOSItems) { item in
                detail(for: item)
                    .tabItem { Label(item.title, systemImage: item.systemImage) }
                    .tag(item)
            }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .background(ThemedWindowBackground())
    }

    /// Normalises selection so the iOS `TabView` never points at a macOS-only
    /// (server) destination.
    private var iOSSelection: Binding<NavigationItem> {
        Binding(
            get: { NavigationItem.iOSItems.contains(selection) ? selection : .review },
            set: { selection = $0 }
        )
    }
    #endif

    @ViewBuilder
    private func detail(for item: NavigationItem) -> some View {
        switch item {
        case .review:
            ReviewView()
        case .status:
            #if os(macOS)
            StatusView()
            #else
            EmptyView()
            #endif
        case .requests:
            #if os(macOS)
            RequestLogView()
            #else
            EmptyView()
            #endif
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Menu commands

/// Lets the active scene's sidebar selection be driven from the menu bar.
struct SelectedNavigationItemKey: FocusedValueKey {
    typealias Value = Binding<NavigationItem>
}

extension FocusedValues {
    var selectedNavigationItem: Binding<NavigationItem>? {
        get { self[SelectedNavigationItemKey.self] }
        set { self[SelectedNavigationItemKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .environmentObject(ServerHost(demo: true))
        .frame(width: 900, height: 620)
}
