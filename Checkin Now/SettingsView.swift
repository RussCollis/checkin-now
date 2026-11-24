import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Jamf Pro", systemImage: "network") {
                ConnectionSettings()
            }
            Tab("Agent", systemImage: "desktopcomputer.and.arrow.down") {
                AgentSettings()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 520)
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var connectionStatus: String?
    @State private var isTesting = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                TextField("Server URL", text: $model.serverURL, prompt: Text("yourorg.jamfcloud.com"))
                Picker("Authentication", selection: $model.authMethod) {
                    ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                }
                TextField(model.authMethod == .apiClient ? "Client ID" : "Username", text: $model.identifier)
                SecureField(model.authMethod == .apiClient ? "Client Secret" : "Password", text: $model.secret)
            } footer: {
                Text("The secret is stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        isTesting = true
                        Task {
                            connectionStatus = await model.testConnection()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting || model.serverURL.isEmpty)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let connectionStatus {
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text("Privileges: Read Computers and Computer Groups; Create, Read and Update Policies, Scripts and macOS Configuration Profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var isExporting = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                TextField("Org Name", text: $model.orgName, prompt: Text("yourorg"))
                TextField("Trigger Profile", text: $model.profileName)
                LabeledContent("Preference Domain") {
                    Text(model.sanitizedOrgName.isEmpty ? "Set an org name" : TriggerProfile.domain(orgName: model.sanitizedOrgName))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Use the same org name as any jamf-checkin-watcher you've already deployed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Install On", selection: $model.setupGroupID) {
                    Text("All Computers").tag(Int?.none)
                    ForEach(model.groups) { group in
                        Text(group.isSmart ? "\(group.name) (Smart)" : group.name)
                            .tag(Optional(group.id))
                    }
                }
                HStack {
                    Button {
                        Task { await model.setUpJamfPro() }
                    } label: {
                        Label("Set Up in Jamf Pro", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConfigured || model.isSettingUp)
                    if model.isSettingUp { ProgressView().controlSize(.small) }
                    Spacer()
                    Menu("Script") {
                        Button("Copy Agent Setup Script") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(WatcherScript.script(orgName: model.sanitizedOrgName), forType: .string)
                        }
                        Button("Save Agent Setup Script…") { isExporting = true }
                    }
                    .fixedSize()
                    .disabled(model.sanitizedOrgName.isEmpty)
                }
                ForEach(model.setupLog) { entry in
                    LogRow(entry: entry)
                        .font(.callout)
                }
            } header: {
                Text("Install Agent")
            } footer: {
                Text("Creates or updates the script “\(AppModel.agentScriptName)”, the policy “\(AppModel.agentPolicyName)” (once per computer), and the trigger profile. Safe to run again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.isConfigured) {
            if model.groups.isEmpty { await model.loadLists() }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: ScriptDocument(text: WatcherScript.script(orgName: model.sanitizedOrgName)),
            contentType: .shellScript,
            defaultFilename: "CheckinNowAgentSetup.sh"
        ) { _ in }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Checkin Now")
                .font(.title.bold())
            Text("Version \(Bundle.main.shortVersion)")
                .foregroundStyle(.secondary)
            Text("Force Jamf Pro check-ins instantly, by serial number or group.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Text(Credits.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            VStack(spacing: 2) {
                Text("Agent based on jamf-checkin-watcher by mhrono")
                Text("© 2021 Buoy Health, Inc. · Apache License 2.0")
                if let url = Credits.upstreamURL {
                    Link("github.com/mhrono/jamf-checkin-watcher", destination: url)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Wraps the setup script text so it can be saved with `fileExporter`.
struct ScriptDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.shellScript]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

#Preview("Agent") {
    AgentSettings()
        .environment(AppModel())
        .frame(width: 520)
}

#Preview("About") {
    AboutSettings()
        .frame(width: 520)
}
