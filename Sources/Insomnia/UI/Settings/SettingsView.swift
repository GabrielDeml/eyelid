import SwiftUI

// MARK: - Settings tab layout (docs/UX.md §4; ARCHITECTURE.md "UI/Settings/…")
//
// Four toolbar tabs, `Form(.grouped)`, 540 wide. The third tab is "Lid & Safety" on MacBooks, "Safety" on a Mac
// without a lid, and absent on a Mac with neither lid nor battery. Each tab's view is owned by its module:
//   General      GeneralTab      (M4, this folder)
//   Automations  AutomationsTab  (M3) + CLIInstallView as its Command line section (M5)
//   Lid & Safety LidSafetyTab    (M2)
//   Diagnostics  DiagnosticsTab  (M3)

enum SettingsLayout {
    static let width: CGFloat = 540

    /// Which tabs exist on this Mac, in toolbar order.
    static func visibleTabs(hasLid: Bool, hasBattery: Bool) -> [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .lidSafety || hasLid || hasBattery }
    }

    /// Toolbar / window title. "Safety" without a lid (UX §4.3).
    static func title(_ tab: SettingsTab, hasLid: Bool) -> String {
        tab == .lidSafety && !hasLid ? "Safety" : tab.title
    }

    static func symbol(_ tab: SettingsTab, hasLid: Bool) -> String {
        tab == .lidSafety && !hasLid ? "shield.lefthalf.filled" : tab.symbol
    }

    /// Fixed content height per tab: the window resizes between tabs, never while one is shown (Forms scroll).
    static func height(_ tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 640
        case .automations: return 620
        case .lidSafety: return 640
        case .diagnostics: return 640
        }
    }

    /// Where a request for a hidden tab lands.
    static func resolve(_ tab: SettingsTab, visible: [SettingsTab]) -> SettingsTab {
        visible.contains(tab) ? tab : .general
    }
}

/// One tab's content at its fixed size. The only place that names the other modules' tab types.
struct SettingsTabContent: View {
    let tab: SettingsTab

    var body: some View {
        content
            .frame(width: SettingsLayout.width, height: SettingsLayout.height(tab))
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general: GeneralTab()
        case .automations: AutomationsTab { CLIInstallView() }
        case .lidSafety: LidSafetyTab()
        case .diagnostics: DiagnosticsTab()
        }
    }
}

/// A secondary footnote row inside a Form section (hints like "Include ⌘ or ⌃.").
struct SettingsFootnote: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(text).foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
