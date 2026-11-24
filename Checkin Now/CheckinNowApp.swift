import SwiftUI

/// Credits shown in the About panel, Settings › About and the sidebar footer.
enum Credits {
    static let copyright = "© 2026 Russell Collis · MIT License"
    static let upstream = "Agent based on jamf-checkin-watcher by mhrono · © 2021 Buoy Health, Inc. · Apache License 2.0"
    static let upstreamURL = URL(string: "https://github.com/mhrono/jamf-checkin-watcher")
}

@main struct CheckinNowApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Checkin Now", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Checkin Now") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: aboutCredits(),
                    ])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// About panel credits: tagline, license, and a link to the upstream project.
    private func aboutCredits() -> NSAttributedString {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "Force Jamf Pro check-ins instantly, by serial number or group.\n\n\(Credits.copyright)\n\(Credits.upstream)\n",
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
        )
        if let url = Credits.upstreamURL {
            credits.append(NSAttributedString(string: url.absoluteString, attributes: [.font: small, .link: url]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        return credits
    }
}
