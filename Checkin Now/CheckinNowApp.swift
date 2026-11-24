import SwiftUI

@main struct CheckinNowApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Checkin Now", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Checkin Now") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Force Jamf Pro check-ins instantly, by serial number or group.\nBased on jamf-checkin-watcher.",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]
                        ),
                    ])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
