import SwiftUI

enum ResultsTab: Hashable {
    case targets, run, activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: ResultsTab = .targets

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 700)
        } detail: {
            ResultsPanel(tab: tab)
                // Keep the detail's minimum small so the sidebar can be dragged wider.
                .frame(minWidth: 420)
        }
        .navigationTitle("Checkin Now")
        .navigationSubtitle(model.serverHost ?? "Not connected")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Targets").tag(ResultsTab.targets)
                    Text("Last Run").tag(ResultsTab.run)
                    Text("Activity").tag(ResultsTab.activity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await model.loadLists()
                        await model.refreshRun()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload groups, policies and run status from Jamf Pro")
                .disabled(!model.isConfigured || model.isLoadingLists)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Jamf Pro connection and agent setup")
            }
        }
        .frame(minWidth: 760, minHeight: 720)
        .task(id: model.isConfigured) { await model.loadLists() }
        // Keep the tables current between runs; during a run the monitor refreshes faster.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if model.isConfigured, !model.isMonitoring, !model.isRunning, model.hasPreview || model.run != nil {
                    await model.refreshRun()
                }
            }
        }
        // Jump to the run as soon as one starts, and back to targets when they change.
        .onChange(of: model.run?.triggeredAt) { _, newValue in
            if newValue != nil { tab = .run }
        }
        .onChange(of: model.isLoadingPreview) { _, loading in
            if loading && !model.isRunning { tab = .targets }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            if !model.isConfigured {
                Section {
                    Label("Connect to Jamf Pro to get started.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    SettingsLink { Text("Open Settings…") }
                }
            }

            Section("Target") {
                Picker("Target", selection: $model.targetKind) {
                    Text("Serial Numbers").tag(TargetKind.serials)
                    Text("Group").tag(TargetKind.group)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                switch model.targetKind {
                case .serials:
                    TextEditor(text: $model.serialsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Serial numbers")
                    HStack {
                        Text(model.serials.isEmpty
                             ? "One per line, or comma separated"
                             : "\(model.serials.count) serial number\(model.serials.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.isLoadingPreview { ProgressView().controlSize(.small) }
                        Button("Look Up") {
                            Task { await model.loadPreview() }
                        }
                        .disabled(model.serials.isEmpty || !model.isConfigured || model.isLoadingPreview)
                    }
                case .group:
                    Picker("Group", selection: $model.selectedGroupID) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(model.groups) { group in
                            Text(group.isSmart ? "\(group.name) (Smart)" : group.name)
                                .tag(Optional(group.id))
                        }
                    }
                    if model.isLoadingPreview {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading members…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .task(id: model.selectedGroupID) {
                if model.targetKind == .group { await model.loadPreview() }
            }

            Section {
                Picker("Policy", selection: $model.selectedPolicyID) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(model.policies) { policy in
                        Text("\(policy.name) (\(policy.id))").tag(Optional(policy.id))
                    }
                }
                Toggle("Update inventory after policy", isOn: $model.policyUpdatesInventory)
            } header: {
                Text("Policy")
            } footer: {
                Text("Used by Run Policy. Check-in and inventory don't need a policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SidebarMacsSection()
            SidebarActivitySection()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionPanel()
        }
    }
}

/// Live list of the targeted Macs, with run progress and help for stragglers.
private struct SidebarMacsSection: View {
    @Environment(AppModel.self) private var model
    private let limit = 8

    /// The current run, if it's for the Macs currently targeted.
    private var matchingRun: CheckinRun? {
        guard let run = model.run, model.hasPreview else { return model.run }
        return Set(run.macs.map(\.id)) == Set(model.preview.map(\.id)) ? run : nil
    }

    private var macs: [TargetMac] {
        matchingRun?.macs ?? model.preview
    }

    var body: some View {
        if !macs.isEmpty {
            Section {
                ForEach(macs.prefix(limit)) { mac in
                    SidebarMacRow(mac: mac, run: matchingRun,
                                  diagnosis: matchingRun?.waitingMacs.contains(where: { $0.id == mac.id }) == true ? model.diagnoses[mac.id] : nil)
                }
                if macs.count > limit {
                    Text("+ \(macs.count - limit) more on the Targets tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let run = matchingRun, !run.waitingMacs.isEmpty, !run.isComplete {
                    HStack {
                        Button {
                            Task { await model.diagnoseWaitingMacs() }
                        } label: {
                            Label(model.isDiagnosing ? "Checking…" : "Diagnose", systemImage: "stethoscope")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Check each waiting Mac's Jamf Pro history to see why it hasn't finished")
                        .disabled(model.isDiagnosing)
                        Button {
                            Task { await model.wakeWaitingMacs() }
                        } label: {
                            Label("Wake", systemImage: "bell.badge")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Send an MDM blank push so waiting Macs pick up the trigger")
                        .disabled(model.isNudging || model.isRunning)
                        Button {
                            Task { await model.resendToWaitingMacs() }
                        } label: {
                            Label("Resend", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Send the trigger again to only the waiting Macs")
                        .disabled(model.isNudging || model.isRunning)
                    }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                }
            } header: {
                HStack {
                    Text(matchingRun == nil ? "Macs" : "Progress")
                    Spacer()
                    if let run = matchingRun {
                        Text("\(run.doneCount)/\(run.macs.count) done")
                            .monospacedDigit()
                    }
                }
            } footer: {
                if let run = matchingRun, !run.waitingMacs.isEmpty, !run.isComplete {
                    Text("Waiting Macs are checked automatically after 2 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SidebarMacRow: View {
    let mac: TargetMac
    let run: CheckinRun?
    var diagnosis: MacDiagnosis?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(now: context.date))
                        .frame(width: 8, height: 8)
                    Text(mac.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(detail(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let diagnosis {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(diagnosis.summary, systemImage: diagnosis.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(diagnosis.isSevere ? .red : .orange)
                        Text(diagnosis.advice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                }
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        if let diagnosis { return "\(diagnosis.summary). \(diagnosis.advice)" }
        return mac.lastSeen.map { "Last seen by Jamf \($0.formatted(date: .abbreviated, time: .standard))" } ?? "Never checked in"
    }

    private func color(now: Date) -> Color {
        if let run {
            if run.isDone(mac) { return .green }
            return run.state(of: mac) == .checkedIn ? .blue : .orange
        }
        guard let contact = mac.lastSeen else { return .red }
        switch now.timeIntervalSince(contact) {
        case ..<3_600: return .green
        case ..<86_400: return .orange
        default: return .red
        }
    }

    private func detail(now: Date) -> String {
        if let run {
            if run.isDone(mac) { return "Done" }
            if run.state(of: mac) == .checkedIn {
                return run.expectsInventory ? "Updating inventory…" : "Checked in"
            }
            let minutes = Int(now.timeIntervalSince(run.triggeredAt) / 60)
            return minutes < 1 ? "Waiting" : "Waiting \(minutes)m"
        }
        guard let contact = mac.lastSeen else { return "Never" }
        if now.timeIntervalSince(contact) < 60 { return "Just now" }
        return contact.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// The latest few log entries, so progress is visible from any tab.
private struct SidebarActivitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Recent Activity") {
            if model.log.isEmpty {
                Text("Lookups, check-ins and errors appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.log.suffix(5).reversed()) { entry in
                    LogRow(entry: entry)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// Large one-click action buttons pinned to the bottom of the sidebar.
private struct ActionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Run on")
                    .foregroundStyle(.secondary)
                Text(targetCount)
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.callout)

            ActionButton(
                action: .checkinAndInventory,
                title: "Check In + Update Inventory",
                detail: "jamf policy, then jamf recon",
                symbol: "bolt.fill",
                prominent: true
            )
            .keyboardShortcut(.return, modifiers: .command)

            HStack(spacing: 10) {
                ActionButton(action: .checkin, title: "Check In", detail: "jamf policy", symbol: "arrow.triangle.2.circlepath", stacked: true)
                ActionButton(action: .inventory, title: "Update Inventory", detail: "jamf recon", symbol: "list.clipboard", stacked: true)
            }

            ActionButton(
                action: .policy(updateInventory: model.policyUpdatesInventory),
                title: "Run Policy",
                detail: policyDetail,
                symbol: "shippingbox"
            )

            VStack(spacing: 2) {
                Text("Checkin Now \(Bundle.main.shortVersion) · \(Credits.copyright)")
                Text(Credits.upstream)
                    .multilineTextAlignment(.center)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.bar)
    }

    private var policyDetail: String {
        guard let id = model.selectedPolicyID else { return "Choose a policy above" }
        let name = model.policies.first { $0.id == id }?.name ?? "ID \(id)"
        return model.policyUpdatesInventory ? "\(name), then jamf recon" : name
    }

    /// How many Macs will be targeted, when known.
    private var targetCount: String {
        switch model.targetKind {
        case .serials:
            let count = model.hasPreview ? model.preview.count : model.serials.count
            return count == 0 ? "no targets yet" : "\(count) Mac\(count == 1 ? "" : "s")"
        case .group:
            guard let id = model.selectedGroupID else { return "no group yet" }
            let name = model.groups.first { $0.id == id }?.name ?? "group"
            return model.hasPreview ? "\(name) (\(model.preview.count))" : name
        }
    }
}

private struct ActionButton: View {
    @Environment(AppModel.self) private var model
    let action: RunAction
    let title: String
    let detail: String
    let symbol: String
    var prominent = false
    /// Icon above the title, for the half-width buttons.
    var stacked = false

    private var isSending: Bool { model.runningAction == action }

    @ViewBuilder private var icon: some View {
        if isSending {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: symbol)
        }
    }

    private var titleText: Text {
        Text(isSending ? "Sending…" : title)
    }

    var body: some View {
        Button {
            Task { await model.forceCheckin(action) }
        } label: {
            Group {
                if stacked {
                    VStack(spacing: 4) {
                        icon.font(.title2)
                        titleText
                            .font(.callout.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .opacity(0.75)
                    }
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    HStack(spacing: 10) {
                        icon
                            .font(prominent ? .title2 : .title3)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            titleText
                                .font(prominent ? .headline : .callout.weight(.semibold))
                            Text(detail)
                                .font(.caption)
                                .opacity(0.75)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: prominent ? 56 : 46)
                }
            }
            .contentShape(Rectangle())
        }
        .modifier(ProminentIf(prominent))
        .controlSize(.large)
        .disabled(!model.canRun(action))
        .help("\(title): \(detail)")
    }
}

/// Bordered-prominent for the main action, bordered for the rest.
private struct ProminentIf: ViewModifier {
    let isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }

    func body(content: Content) -> some View {
        if isOn {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Shared

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(entry.text)
                .textSelection(.enabled)
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var symbol: String {
        switch entry.level {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

#Preview(traits: .fixedLayout(width: 1100, height: 820)) {
    ContentView()
        .environment(AppModel())
}

#Preview("Run in progress", traits: .fixedLayout(width: 1100, height: 900)) {
    let model = AppModel()
    let macs: [TargetMac] = [("UK-V4XKR6XHN4", false), ("UK-X2LQL0M22N", true)].enumerated().map { index, item in
        var mac = TargetMac(ComputerSummary(id: index + 1, name: item.0, serial: String(item.0.dropFirst(3))))
        mac.model = "MacBook Pro (14-inch, 2021)"
        mac.osVersion = "27.2.1"
        mac.lastContact = item.1 ? Date().addingTimeInterval(-40) : Date().addingTimeInterval(-3_000)
        mac.lastReport = item.1 ? Date().addingTimeInterval(-30) : Date().addingTimeInterval(-50_000)
        return mac
    }
    model.targetKind = .group
    model.preview = macs
    model.hasPreview = true
    model.run = CheckinRun(triggeredAt: Date().addingTimeInterval(-240), action: "Check In + Update Inventory",
                           targetDescription: "group “UAT | SG Russ” (2 Macs)", profileID: 42, policyID: "default",
                           expectsCheckin: true, expectsInventory: true, macs: macs, notFound: [], lastRefreshed: Date(), lastSentAt: Date().addingTimeInterval(-240))
    model.diagnoses[1] = MacDiagnosis(kind: .mdmNotResponding, summary: "Online, but trigger pending (8 min)",
                                      advice: "MDM pushes aren't arriving. Try Wake.")
    return ContentView()
        .environment(model)
}
