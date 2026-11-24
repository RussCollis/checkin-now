import SwiftUI

enum ResultsTab: Hashable, CaseIterable {
    case targets, run, activity

    var title: String {
        switch self {
        case .targets: "Targets"
        case .run: "Last Run"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .targets: "desktopcomputer"
        case .run: "bolt.fill"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// The main window, laid out like Patching Dashboard: navy sidebar, white top
/// bar with breadcrumb and instance badge, then the controls beside the results.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: ResultsTab = .targets

    var body: some View {
        HStack(spacing: 0) {
            NavSidebar(tab: $tab)

            VStack(spacing: 0) {
                TopBar(tab: tab)
                HStack(alignment: .top, spacing: 20) {
                    ControlColumn()
                        .frame(width: 330)
                    ResultsPanel(tab: tab)
                        .frame(minWidth: 480)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.content)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1100, minHeight: 720)
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

// MARK: - Navy sidebar

/// Navy navigation column: brand at the top, the result pages, Settings and credits at the bottom.
private struct NavSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: ResultsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("Checkin Now")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 12)

            // A plain stack, not a List: three fixed rows don't need an outline view.
            VStack(alignment: .leading, spacing: 2) {
                heading("Check-ins")
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                ForEach(ResultsTab.allCases, id: \.self) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)

            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jamf Pro connection and agent setup")
            .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text("Checkin Now \(Bundle.main.shortVersion)")
                Text(Credits.copyright)
                Text(Credits.upstream)
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.sidebarDimText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .frame(width: 220)
        .background(Theme.sidebar)
        // Keeps system list text and the scroll indicator light on navy.
        .environment(\.colorScheme, .dark)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.sidebarHeading)
    }

    private func count(for item: ResultsTab) -> String? {
        switch item {
        case .targets:
            return model.hasPreview ? "\(model.preview.count)" : nil
        case .run:
            return model.run.map { "\($0.doneCount)/\($0.macs.count)" }
        case .activity:
            let issues = model.log.filter { $0.level == .warning || $0.level == .error }.count
            return issues > 0 ? "\(issues) issue\(issues == 1 ? "" : "s")" : (model.log.isEmpty ? nil : "\(model.log.count)")
        }
    }

    private func row(_ item: ResultsTab) -> some View {
        let selected = tab == item
        return HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? Theme.sidebarText : Theme.sidebarHeading)
            Text(item.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.sidebarText)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let count = count(for: item) {
                Text(count)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.sidebarText : Theme.sidebarText.opacity(0.75))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Theme.sidebarSelected : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { tab = item }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Top bar

/// White bar across the content area: breadcrumb, refresh and the Jamf Pro instance badge.
private struct TopBar: View {
    @Environment(AppModel.self) private var model
    let tab: ResultsTab

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Checkin Now").foregroundStyle(.secondary)
                Text("/").foregroundStyle(.tertiary)
                Text(tab.title).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .lineLimit(1)

            Spacer(minLength: 12)

            Button {
                Task {
                    await model.loadLists()
                    await model.refreshRun()
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isLoadingLists {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .buttonStyle(.panel)
            .help("Reload groups, policies and run status from Jamf Pro")
            .disabled(!model.isConfigured || model.isLoadingLists)

            // The Jamf Pro server; opens Settings.
            SettingsLink {
                let connected = model.isConfigured
                let tint = !connected ? Theme.grey : (model.groups.isEmpty && !model.isLoadingLists ? Theme.orange : Theme.green)
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(model.serverHost ?? "Not connected")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(connected ? Theme.navy : Theme.grey)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background((connected ? Theme.blue : Theme.grey).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(model.isConfigured ? "Jamf Pro connection settings" : "Connect to Jamf Pro")
            .accessibilityLabel(model.serverHost.map { "Jamf Pro server \($0)" } ?? "Not connected to Jamf Pro")
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Controls

/// Target, policy, progress and recent activity panels, with the run buttons pinned below.
private struct ControlColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.isConfigured {
                        Panel {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Connect to Jamf Pro to get started.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.orange)
                                SettingsLink { Text("Open Settings…") }
                                    .buttonStyle(.panelPrimary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Panel("Target", accessory: {
                        Picker("Target", selection: $model.targetKind) {
                            Text("Serials").tag(TargetKind.serials)
                            Text("Group").tag(TargetKind.group)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }) {
                        VStack(alignment: .leading, spacing: 10) {
                            switch model.targetKind {
                            case .serials:
                                TextEditor(text: $model.serialsText)
                                    .font(.system(size: 13, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .frame(minHeight: 120)
                                    .background(Theme.panelBar, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                                    .accessibilityLabel("Serial numbers")
                                HStack {
                                    Text(model.serials.isEmpty
                                         ? "One per line, or comma separated"
                                         : "\(model.serials.count) serial number\(model.serials.count == 1 ? "" : "s")")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if model.isLoadingPreview { ProgressView().controlSize(.small) }
                                    Button("Look Up") {
                                        Task { await model.loadPreview() }
                                    }
                                    .buttonStyle(.panel)
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
                                    .font(.system(size: 12))
                                }
                            }
                        }
                        .padding(16)
                    }
                    .task(id: model.selectedGroupID) {
                        if model.targetKind == .group { await model.loadPreview() }
                    }

                    Panel("Policy", footer: "Used by Run Policy. Check-in and inventory don't need a policy.") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Policy", selection: $model.selectedPolicyID) {
                                Text("Choose…").tag(Int?.none)
                                ForEach(model.policies) { policy in
                                    Text("\(policy.name) (\(policy.id))").tag(Optional(policy.id))
                                }
                            }
                            .labelsHidden()
                            Toggle("Update inventory after policy", isOn: $model.policyUpdatesInventory)
                        }
                        .font(.system(size: 13))
                        .padding(16)
                    }

                    SidebarMacsSection()
                    SidebarActivitySection()
                }
            }
            .scrollIndicators(.never)

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

    private var waitingFooter: String? {
        guard let run = matchingRun, !run.waitingMacs.isEmpty, !run.isComplete else { return nil }
        return "Waiting Macs are checked automatically after 2 minutes."
    }

    var body: some View {
        if !macs.isEmpty {
            Panel(matchingRun == nil ? "Macs" : "Progress", footer: waitingFooter, accessory: {
                if let run = matchingRun {
                    Text("\(run.doneCount)/\(run.macs.count) done")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(macs.prefix(limit)) { mac in
                        SidebarMacRow(mac: mac, run: matchingRun,
                                      diagnosis: matchingRun?.waitingMacs.contains(where: { $0.id == mac.id }) == true ? model.diagnoses[mac.id] : nil)
                    }
                    if macs.count > limit {
                        Text("+ \(macs.count - limit) more on the Targets page")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let run = matchingRun, !run.waitingMacs.isEmpty, !run.isComplete {
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.diagnoseWaitingMacs() }
                            } label: {
                                WaitingButtonLabel(title: model.isDiagnosing ? "Checking…" : "Diagnose", symbol: "stethoscope")
                            }
                            .help("Check each waiting Mac's Jamf Pro history to see why it hasn't finished")
                            .disabled(model.isDiagnosing)
                            Button {
                                Task { await model.wakeWaitingMacs() }
                            } label: {
                                WaitingButtonLabel(title: "Wake", symbol: "bell.badge")
                            }
                            .help("Send an MDM blank push so waiting Macs pick up the trigger")
                            .disabled(model.isNudging || model.isRunning)
                            Button {
                                Task { await model.resendToWaitingMacs() }
                            } label: {
                                WaitingButtonLabel(title: "Resend", symbol: "arrow.clockwise")
                            }
                            .help("Send the trigger again to only the waiting Macs")
                            .disabled(model.isNudging || model.isRunning)
                        }
                        .buttonStyle(TallPanelButtonStyle())
                        .padding(.top, 4)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Icon above the title, so three buttons fit across the narrow Progress panel.
private struct WaitingButtonLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
            Text(title).font(.system(size: 12))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
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
                        .font(.system(size: 13))
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
                            .foregroundStyle(diagnosis.isSevere ? Theme.red : Theme.orange)
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
            if run.isDone(mac) { return Theme.green }
            return run.state(of: mac) == .checkedIn ? Theme.blue : Theme.updateOrange
        }
        guard let contact = mac.lastSeen else { return Theme.red }
        switch now.timeIntervalSince(contact) {
        case ..<3_600: return Theme.green
        case ..<86_400: return Theme.updateOrange
        default: return Theme.red
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
        Panel("Recent Activity") {
            VStack(alignment: .leading, spacing: 8) {
                if model.log.isEmpty {
                    Text("Lookups, check-ins and errors appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.log.suffix(5).reversed()) { entry in
                        LogRow(entry: entry)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

/// Large one-click action buttons pinned below the control panels.
private struct ActionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel("Run on", detail: targetCount) {
            VStack(spacing: 10) {
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
            }
            .padding(16)
        }
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
                    .frame(maxWidth: .infinity, minHeight: prominent ? 56 : 46)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TallPanelButtonStyle(prominent: prominent))
        .disabled(!model.canRun(action))
        .help("\(title): \(detail)")
    }
}

/// `PanelButtonStyle` colours without its fixed 30 pt height, for buttons with two lines.
private struct TallPanelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Theme.primary : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent ? Color.clear : Theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.45))
            .contentShape(Rectangle())
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
        case .success: Theme.green
        case .warning: Theme.orange
        case .error: Theme.red
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
