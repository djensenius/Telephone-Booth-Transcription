import SwiftUI
import TranscriptionCore

struct ContentView: View {
    @EnvironmentObject var host: ServerHost
    @State private var selectedTab: AppTab = .status

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            GlassTabBar(selection: $selectedTab)

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.Spacing.large)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .status:
            StatusView()
        case .settings:
            SettingsView()
        case .requests:
            RequestLogView()
        }
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case status
    case settings
    case requests

    var id: Self { self }

    var title: String {
        switch self {
        case .status: "Status"
        case .settings: "Settings"
        case .requests: "Requests"
        }
    }

    var systemImage: String {
        switch self {
        case .status: "phone.connection.fill"
        case .settings: "gearshape"
        case .requests: "list.bullet.rectangle"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .status: "1"
        case .settings: "2"
        case .requests: "3"
        }
    }
}

private struct GlassTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(Theme.Fonts.bodyMedium.weight(selection == tab ? .semibold : .medium))
                        .foregroundStyle(selection == tab ? Theme.Colors.onAccent : Theme.Colors.textPrimary)
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.small)
                        .frame(minWidth: 128)
                        .background {
                            selectedBackground(for: tab)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(tab.shortcut, modifiers: [.command])
            }
        }
        .padding(6)
        .glassTabBar()
    }

    @ViewBuilder
    private func selectedBackground(for tab: AppTab) -> some View {
        if selection == tab {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.Colors.accent.opacity(0.92))
        }
    }
}

private struct GlassTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(Theme.Colors.secondaryBackground.opacity(0.5)),
                in: .rect(cornerRadius: Theme.cornerRadius + 8)
            )
        } else {
            content
                .background(Theme.Colors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius + 8))
        }
    }
}

private extension View {
    func glassTabBar() -> some View { modifier(GlassTabBarModifier()) }
}
