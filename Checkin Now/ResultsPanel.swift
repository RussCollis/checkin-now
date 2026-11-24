import SwiftUI

/// Detail area: the Macs the current target resolves to, the live status of
/// the most recent check-in run, and the activity log.
struct ResultsPanel: View {
    @Environment(AppModel.self) private var model
    let tab: ResultsTab

    var body: some View {
        Group {
            if !model.isConfigured {
                ContentUnavailableView {
                    Label("Connect to Jamf Pro", systemImage: "network")
                } description: {
                    Text("Add your server, credentials and org name in Settings.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                switch tab {
                case .targets:
                    TargetsView()
                case .run:
                    if let run = model.run {
                        RunView(run: run)
                    } else {
                        ContentUnavailableView(
                            "No Check-ins Yet",
                            systemImage: "bolt.horizontal.circle",
                            description: Text("Choose a target and click Check In Now. Each Mac's progress appears here.")
                        )
                    }
                case .activity:
                    ActivityView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Title strip shown above each table.
private struct PanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct TargetsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasPreview {
            VStack(spacing: 0) {
                PanelHeader(title: title, subtitle: subtitle) {
                    EmptyView()
                }
                HStack(spacing: 10) {
                    StatCard(title: "Macs", value: model.preview.count, symbol: "desktopcomputer", tint: .accentColor)
                    StatCard(title: "Seen < 1 h", value: count(where: { $0.lastSeen.map(isRecent) ?? false }),
                             symbol: "checkmark.circle", tint: .green)
                    StatCard(title: "Inventory today", value: count(where: { $0.lastReport.map(Calendar.current.isDateInToday) ?? false }),
                             symbol: "list.clipboard", tint: .blue)
                    StatCard(title: "Not seen 24 h+", value: count(where: { mac in mac.lastSeen.map { $0 < Date().addingTimeInterval(-86_400) } ?? true }),
                             symbol: "exclamationmark.triangle", tint: .orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                if !model.previewNotFound.isEmpty {
                    NotFoundBanner(serials: model.previewNotFound)
                }
                Divider()
                MacTable(macs: model.preview, run: nil)
            }
        } else if model.isLoadingPreview {
            ProgressView(model.targetKind == .group ? "Loading group members…" : "Looking up serial numbers…")
        } else {
            ContentUnavailableView(
                "No Targets",
                systemImage: "desktopcomputer",
                description: Text(model.targetKind == .group
                                  ? "Choose a computer group to list its members."
                                  : "Enter serial numbers and click Look Up.")
            )
        }
    }

    private func count(where predicate: (TargetMac) -> Bool) -> Int {
        model.preview.filter(predicate).count
    }

    private func isRecent(_ date: Date) -> Bool {
        date > Date().addingTimeInterval(-3_600)
    }

    private var subtitle: String {
        if model.targetKind == .group {
            let isSmart = model.groups.first { $0.id == model.selectedGroupID }?.isSmart ?? false
            return "\(isSmart ? "Smart" : "Static") group · current members from Jamf Pro"
        }
        return "\(model.serials.count) serial number\(model.serials.count == 1 ? "" : "s") looked up in Jamf Pro"
    }

    private var title: String {
        if model.targetKind == .group,
           let group = model.groups.first(where: { $0.id == model.selectedGroupID }) {
            return group.name
        }
        return "Serial Number Lookup"
    }
}

private struct RunView: View {
    @Environment(AppModel.self) private var model
    let run: CheckinRun

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: run.action,
                subtitle: "\(run.targetDescription) · sent \(run.triggeredAt.formatted(date: .omitted, time: .standard))"
            ) {
                if model.isMonitoring {
                    ProgressView().controlSize(.small)
                    Text("Watching…").foregroundStyle(.secondary)
                    Button("Stop") { model.stopMonitoring() }
                } else if let refreshed = run.lastRefreshed {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !run.macs.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        StatCard(title: "Targeted", value: run.macs.count, symbol: "desktopcomputer", tint: .accentColor)
                        if run.expectsCheckin {
                            StatCard(title: "Checked in", value: run.checkedInCount, symbol: "arrow.triangle.2.circlepath", tint: .blue)
                        }
                        if run.expectsInventory {
                            StatCard(title: "Inventory updated", value: run.inventoryCount, symbol: "list.clipboard", tint: .green)
                        }
                        StatCard(title: "Waiting", value: run.waitingMacs.count, symbol: "clock", tint: .orange)
                    }
                    ProgressView(value: Double(run.doneCount) + Double(run.updatingInventoryCount) * 0.5, total: Double(run.macs.count)) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(run.updatingInventoryCount > 0
                             ? "\(run.doneCount) of \(run.macs.count) done · \(run.updatingInventoryCount) updating inventory"
                             : "\(run.doneCount) of \(run.macs.count) done")
                    }
                    .tint(run.isComplete ? .green : .accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if !run.notFound.isEmpty {
                NotFoundBanner(serials: run.notFound)
            }
            Divider()
            MacTable(macs: run.macs, run: run)
        }
    }
}

private struct ActivityView: View {
    enum Filter: Hashable { case all, issues }

    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var search = ""

    private var entries: [LogEntry] {
        model.log.reversed().filter { entry in
            (filter == .all || entry.level == .warning || entry.level == .error)
                && (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search))
        }
    }

    /// Entries grouped by the hour they happened in, newest first.
    private var hours: [(start: Date, entries: [LogEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.dateInterval(of: .hour, for: entry.date)?.start ?? entry.date
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        if model.log.isEmpty {
            ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle",
                                   description: Text("Lookups, check-ins and errors from the last 24 hours appear here."))
        } else {
            VStack(spacing: 0) {
                PanelHeader(title: "Activity", subtitle: subtitle) {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(Filter.all)
                        Text("Issues").tag(Filter.issues)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Button("Copy") { copy() }
                        .help("Copy the shown activity as text")
                    Button("Clear") { model.log.removeAll() }
                }
                Divider()
                if entries.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        ForEach(hours, id: \.start) { hour in
                            Section(hour.start.formatted(.dateTime.weekday(.wide).hour().minute())) {
                                ForEach(hour.entries) { LogRow(entry: $0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let issues = model.log.filter { $0.level == .warning || $0.level == .error }.count
        return "Last 24 hours · \(model.log.count) event\(model.log.count == 1 ? "" : "s") · \(issues) issue\(issues == 1 ? "" : "s")"
    }

    private func copy() {
        let text = entries.reversed()
            .map { "\($0.date.formatted(date: .abbreviated, time: .standard))  \($0.level.rawValue.uppercased())  \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Compact metric tile used above the tables.
private struct StatCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
                .lineLimit(1)
            Text(value, format: .number)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .animation(.default, value: value)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct NotFoundBanner: View {
    let serials: [String]

    var body: some View {
        Label("Not found in Jamf Pro: \(serials.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.1))
    }
}

/// One table row: a Mac plus the values its columns sort by.
private struct MacRow: Identifiable {
    let mac: TargetMac
    /// Done sorts after checked in, which sorts after waiting.
    let statusRank: Int
    let diagnosis: MacDiagnosis?

    var id: TargetMac.ID { mac.id }
    // Missing values sort as empty strings or the earliest date.
    var name: String { mac.name }
    var serial: String { mac.serial }
    var model: String { mac.model ?? "" }
    var osVersion: String { mac.osVersion ?? "" }
    var lastSeen: Date { mac.lastSeen ?? .distantPast }
    var lastContact: Date { mac.lastContact ?? .distantPast }
    var lastReport: Date { mac.lastReport ?? .distantPast }
    var details: String { diagnosis?.summary ?? "" }
}

/// A sortable column. The chosen column and direction are saved in user
/// defaults, so every table shares one sort and it's kept between launches.
private enum MacSortColumn: String, CaseIterable {
    case status, name, serial, model, osVersion, lastSeen, lastContact, lastReport, details

    /// Status and Details only exist while a run is showing.
    var needsRun: Bool { self == .status || self == .details }

    /// Must match the comparator each `TableColumn(_:value:)` builds, so the
    /// header shows the sort arrow. String columns use localized standard order.
    func comparator(_ order: SortOrder) -> KeyPathComparator<MacRow> {
        switch self {
        case .status: KeyPathComparator(\.statusRank, order: order)
        case .name: KeyPathComparator(\.name, comparator: .localizedStandard, order: order)
        case .serial: KeyPathComparator(\.serial, comparator: .localizedStandard, order: order)
        case .model: KeyPathComparator(\.model, comparator: .localizedStandard, order: order)
        case .osVersion: KeyPathComparator(\.osVersion, comparator: .localizedStandard, order: order)
        case .lastSeen: KeyPathComparator(\.lastSeen, order: order)
        case .lastContact: KeyPathComparator(\.lastContact, order: order)
        case .lastReport: KeyPathComparator(\.lastReport, order: order)
        case .details: KeyPathComparator(\.details, comparator: .localizedStandard, order: order)
        }
    }

    init?(_ comparator: KeyPathComparator<MacRow>) {
        guard let match = Self.allCases.first(where: { $0.comparator(.forward).keyPath == comparator.keyPath }) else {
            return nil
        }
        self = match
    }
}

/// Table of Macs. With a run, the first column shows each Mac's check-in state.
/// Click a column header to sort A–Z / 0–9; click again for Z–A / 9–0.
private struct MacTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let macs: [TargetMac]
    let run: CheckinRun?

    @State private var selection = Set<TargetMac.ID>()
    /// Empty until a header is clicked, so the original order shows first.
    @AppStorage("macTableSortColumn") private var sortColumn = ""
    @AppStorage("macTableSortAscending") private var sortAscending = true
    /// Row order, worked out only when the sort or the set of Macs changes, so
    /// rows don't jump around as Macs check in during a run.
    @State private var orderedIDs: [TargetMac.ID] = []

    /// The saved sort, ignored when its column isn't in this table.
    private var activeColumn: MacSortColumn? {
        guard let column = MacSortColumn(rawValue: sortColumn), run != nil || !column.needsRun else { return nil }
        return column
    }

    private var sortOrder: Binding<[KeyPathComparator<MacRow>]> {
        Binding {
            activeColumn.map { [$0.comparator(sortAscending ? .forward : .reverse)] } ?? []
        } set: { newValue in
            guard let first = newValue.first, let column = MacSortColumn(first) else {
                sortColumn = ""
                return
            }
            sortColumn = column.rawValue
            sortAscending = first.order == .forward
        }
    }

    /// Rows in their original order, with current data.
    private var unsortedRows: [MacRow] {
        let waitingIDs = Set(run?.waitingMacs.map(\.id) ?? [])
        return macs.map { mac in
            var rank = 0
            if let run {
                rank = run.isDone(mac) ? 3 : run.state(of: mac).rawValue
            }
            let diagnosis = waitingIDs.contains(mac.id) ? model.diagnoses[mac.id] : nil
            return MacRow(mac: mac, statusRank: rank, diagnosis: diagnosis)
        }
    }

    /// Current data laid out in the last sorted order. Macs not yet placed go last.
    private var rows: [MacRow] {
        let current = unsortedRows
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = Set(orderedIDs)
        return orderedIDs.compactMap { byID[$0] } + current.filter { !placed.contains($0.id) }
    }

    private func resort() {
        guard let column = activeColumn else {
            orderedIDs = macs.map(\.id)
            return
        }
        // Rows with equal values (same status, model, macOS…) fall back to name, then serial.
        let comparators = [column.comparator(sortAscending ? .forward : .reverse),
                           MacSortColumn.name.comparator(.forward),
                           MacSortColumn.serial.comparator(.forward)]
        orderedIDs = unsortedRows.sorted(using: comparators).map(\.id)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: sortOrder) {
            if let run {
                TableColumn("Status", value: \.statusRank) { row in
                    StatusBadge(state: run.state(of: row.mac), isDone: run.isDone(row.mac),
                                updatingInventory: run.expectsInventory)
                }
                .width(min: 70, ideal: 160, max: 190)
            }
            TableColumn("Name", value: \.name) { row in
                Label(row.mac.name, systemImage: "laptopcomputer")
                    .labelStyle(TintedIconLabelStyle(tint: .secondary))
            }
            .width(min: 90, ideal: 150)
            TableColumn("Serial", value: \.serial) { row in
                Text(row.mac.serial).monospaced()
            }
            .width(min: 70, ideal: 120, max: 150)
            TableColumn("Model", value: \.model) { row in
                Text(row.mac.model ?? "—")
                    .help(row.mac.model ?? "")
            }
            .width(min: 60, ideal: 160)
            TableColumn("macOS", value: \.osVersion) { row in
                Text(row.mac.osVersion ?? "—")
            }
            .width(min: 40, ideal: 60, max: 80)
            TableColumn("Last Seen", value: \.lastSeen) { row in
                DateCell(date: row.mac.lastSeen, showsFreshness: true)
            }
            .width(min: 60, ideal: 115, max: 160)
            TableColumn("Last Contact", value: \.lastContact) { row in
                // Jamf Pro's own "Last Check-in" (last contact time), unadjusted.
                DateCell(date: row.mac.lastContact, showsFreshness: false)
            }
            .width(min: 60, ideal: 110, max: 160)
            TableColumn("Last Inventory", value: \.lastReport) { row in
                DateCell(date: row.mac.lastReport, showsFreshness: false)
            }
            .width(min: 60, ideal: 105, max: 160)
            if run != nil {
                TableColumn("Details", value: \.details) { row in
                    if let diagnosis = row.diagnosis {
                        Label(diagnosis.summary, systemImage: diagnosis.symbol)
                            .modifier(RowTint(diagnosis.isSevere ? .red : .orange))
                            .help(diagnosis.advice)
                    } else {
                        Text("")
                    }
                }
                .width(min: 60, ideal: 260)
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .onAppear(perform: resort)
        .onChange(of: macs.map(\.id)) { resort() }
        .onChange(of: sortColumn) { resort() }
        .onChange(of: sortAscending) { resort() }
        .contextMenu(forSelectionType: TargetMac.ID.self) { ids in
            if let id = ids.first, let url = model.jamfURL(forComputer: id) {
                Button("Open in Jamf Pro") { openURL(url) }
            }
            Button("Copy Serial Numbers") {
                let serials = macs.filter { ids.contains($0.id) }.map(\.serial).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serials, forType: .string)
            }
        } primaryAction: { ids in
            if let id = ids.first, let url = model.jamfURL(forComputer: id) { openURL(url) }
        }
    }
}

private struct StatusBadge: View {
    let state: MacCheckinState
    let isDone: Bool
    /// The run still expects inventory after check-in.
    var updatingInventory = false

    var body: some View {
        if isDone {
            Label("Done", systemImage: "checkmark.circle.fill")
                .modifier(RowTint(.green))
        } else if state == .checkedIn {
            Label(updatingInventory ? "Updating Inventory" : "Checked In",
                  systemImage: updatingInventory ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .modifier(RowTint(.accentColor))
        } else {
            Label("Waiting", systemImage: "clock")
                .modifier(RowTint(.orange))
        }
    }
}

/// Colors text, but switches to the standard color on a selected (highlighted)
/// table row so it stays readable against the selection.
private struct RowTint: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    let color: Color
    init(_ color: Color) { self.color = color }

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
    }
}

private struct DateCell: View {
    let date: Date?
    let showsFreshness: Bool

    var body: some View {
        if let date {
            // Re-render every 30 seconds so "x min ago" stays current.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    if showsFreshness {
                        Circle()
                            .fill(freshness(of: date, now: context.date))
                            .frame(width: 7, height: 7)
                    }
                    Text(relative(date, now: context.date))
                        .monospacedDigit()
                }
            }
            .help(date.formatted(date: .abbreviated, time: .standard))
        } else {
            Text("Never").foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// Green within an hour, orange within a day, red after that.
    private func freshness(of date: Date, now: Date) -> Color {
        switch now.timeIntervalSince(date) {
        case ..<3_600: .green
        case ..<86_400: .orange
        default: .red
        }
    }
}

#Preview("Targets") {
    let model = AppModel()
    model.preview = (1...4).map { index in
        var mac = TargetMac(ComputerSummary(id: index, name: "MacBook-\(index)", serial: "C02XK0\(index)ABCD"))
        mac.model = "MacBook Pro (14-inch, M4)"
        mac.osVersion = "27.2"
        mac.lastContact = Date().addingTimeInterval(Double(-index * 400))
        mac.lastReport = Date().addingTimeInterval(Double(-index * 3600))
        return mac
    }
    model.hasPreview = true
    return ResultsPanel(tab: .targets)
        .environment(model)
        .frame(width: 820, height: 300)
}

#Preview("Run") {
    let model = AppModel()
    let started = Date().addingTimeInterval(-90)
    let macs: [TargetMac] = (1...5).map { index in
        var mac = TargetMac(ComputerSummary(id: index, name: "UK-MAC\(index)XKR6", serial: "C02XK0\(index)ABCD"))
        mac.model = "MacBook Pro (14-inch, 2021)"
        mac.osVersion = "27.2.1"
        mac.lastContact = index <= 3 ? Date().addingTimeInterval(-30) : Date().addingTimeInterval(Double(-index * 5000))
        mac.lastReport = index <= 2 ? Date().addingTimeInterval(-20) : Date().addingTimeInterval(-90_000)
        return mac
    }
    model.run = CheckinRun(triggeredAt: started, action: "Check In + Update Inventory", targetDescription: "group “UAT | SG Russ” (5 Macs)",
                           profileID: 42, policyID: "default", expectsCheckin: true, expectsInventory: true, macs: macs, notFound: [], lastRefreshed: Date(), lastSentAt: started)
    return ResultsPanel(tab: .run)
        .environment(model)
        .frame(width: 1000, height: 420)
}
