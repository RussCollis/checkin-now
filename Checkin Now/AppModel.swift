import Foundation
import Observation

enum TargetKind: String, CaseIterable, Identifiable {
    case serials
    case group

    var id: String { rawValue }
}

/// What the agent on each Mac should run.
enum CheckinKind: String, CaseIterable, Identifiable {
    /// `jamf policy` (optionally followed by `jamf recon`).
    case checkin
    /// `jamf recon` only.
    case inventory
    /// `jamf policy -id N` (optionally followed by `jamf recon`).
    case policy

    var id: String { rawValue }
}

/// One of the action buttons: what to run, and whether to update inventory afterwards.
struct RunAction: Hashable {
    let kind: CheckinKind
    let updateInventory: Bool

    static let checkinAndInventory = RunAction(kind: .checkin, updateInventory: true)
    static let checkin = RunAction(kind: .checkin, updateInventory: false)
    static let inventory = RunAction(kind: .inventory, updateInventory: true)
    static func policy(updateInventory: Bool) -> RunAction {
        RunAction(kind: .policy, updateInventory: updateInventory)
    }
}

struct LogEntry: Identifiable, Codable {
    enum Level: String, Codable { case info, success, warning, error }

    let id: UUID
    let date: Date
    let level: Level
    let text: String

    init(level: Level, text: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.level = level
        self.text = text
    }
}

/// Saves the activity log to Application Support and keeps only the last 24 hours.
enum ActivityStore {
    static let retention: TimeInterval = 24 * 60 * 60
    private static let maxEntries = 5_000

    private static var fileURL: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Checkin Now", directoryHint: .isDirectory) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "activity.json")
    }

    static func prune(_ entries: [LogEntry], now: Date = Date()) -> [LogEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(entries.filter { $0.date >= cutoff }.suffix(maxEntries))
    }

    static func load() -> [LogEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LogEntry].self, from: data) else { return [] }
        return prune(entries)
    }

    static func save(_ entries: [LogEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// A targeted Mac, with the inventory times used to tell whether it has checked in.
struct TargetMac: Identifiable, Hashable {
    let id: Int
    var name: String
    var serial: String
    var model: String?
    var osVersion: String?
    var lastContact: Date?
    var lastReport: Date?
    var managementID: String?

    /// When Jamf Pro last heard from the Mac. An inventory update is also contact,
    /// and Jamf doesn't always bump the check-in time for it, so use the newer.
    var lastSeen: Date? {
        [lastContact, lastReport].compactMap { $0 }.max()
    }

    init(_ summary: ComputerSummary) {
        id = summary.id
        name = summary.name
        serial = summary.serial
    }

    mutating func apply(_ status: ComputerStatus) {
        name = status.name
        if !status.serial.isEmpty { serial = status.serial }
        model = status.model
        osVersion = status.osVersion
        lastContact = status.lastContact
        lastReport = status.lastReport
        managementID = status.managementID ?? managementID
    }
}

enum MacCheckinState: Int, Comparable {
    case waiting, checkedIn, inventoryUpdated

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a Mac hasn't finished yet, worked out from its Jamf Pro history.
struct MacDiagnosis: Hashable {
    enum Kind { case pending, mdmNotResponding, stuck, deferred, failed, noAgent, delivered, unclear, unknown }

    let kind: Kind
    let summary: String
    let advice: String
    let checkedAt = Date()

    /// Failures and stuck queues are red; everything else is a warning.
    var isSevere: Bool { kind == .failed || kind == .stuck }

    var symbol: String {
        switch kind {
        case .pending: "antenna.radiowaves.left.and.right.slash"
        case .mdmNotResponding: "bolt.horizontal.circle"
        case .stuck: "tray.full"
        case .deferred: "hourglass"
        case .failed: "xmark.octagon"
        case .noAgent: "puzzlepiece.extension"
        case .delivered: "gearshape.2"
        case .unclear, .unknown: "questionmark.circle"
        }
    }

    /// Explains a waiting Mac from its MDM commands and policy logs since `since`.
    /// `lastContact` (the Jamf agent's last check-in) tells us whether the Mac is online.
    static func make(history: ComputerHistory, since: Date, agentPolicyID: Int?, lastContact: Date? = nil, now: Date = Date()) -> MacDiagnosis {
        // Profile installs appear as "InstallProfile" / "Install Configuration Profile".
        func isProfile(_ command: ComputerHistory.Command) -> Bool {
            command.name.lowercased().contains("profile") && !command.name.lowercased().contains("remove")
        }
        func isRecent(_ command: ComputerHistory.Command) -> Bool {
            (command.date ?? .distantPast) >= since.addingTimeInterval(-30)
        }
        func minutes(since date: Date) -> String {
            let value = max(1, Int(now.timeIntervalSince(date) / 60))
            return value < 120 ? "\(value) min" : "\(value / 60) h"
        }

        if let failed = history.failed.first(where: { isProfile($0) && isRecent($0) }) {
            return MacDiagnosis(kind: .failed,
                                summary: "Trigger profile failed to install\(failed.status.map { ": \($0)" } ?? "")",
                                advice: "Check the Mac's MDM enrollment in Jamf Pro, then Resend.")
        }

        // A day-old backlog means the Mac's MDM queue is stuck, whatever this run did.
        let staleCount = history.pending.filter { ($0.date ?? now) < now.addingTimeInterval(-86_400) }.count
        if staleCount >= 3, let oldest = history.pending.compactMap(\.date).min() {
            return MacDiagnosis(kind: .stuck,
                                summary: "MDM queue stuck: \(history.pending.count) commands pending, oldest \(minutes(since: oldest))",
                                advice: "In Jamf Pro, open the Mac's Management tab, cancel the pending commands, then Resend. If it continues, re-enroll the Mac's MDM profile.")
        }

        // Jamf reuses a still-pending install command instead of queuing a new one,
        // so a pending trigger from an earlier run still counts.
        if let pending = history.pending.first(where: { isProfile($0) && ($0.date ?? now) > now.addingTimeInterval(-86_400) }) {
            if pending.status?.lowercased().contains("not now") == true {
                return MacDiagnosis(kind: .deferred,
                                    summary: "Mac deferred the trigger (NotNow)",
                                    advice: "It's usually locked or busy. It will install when the Mac is unlocked.")
            }
            let waited = pending.date.map { " (\(minutes(since: $0)))" } ?? ""
            if let lastContact, now.timeIntervalSince(lastContact) < 3_600 {
                return MacDiagnosis(kind: .mdmNotResponding,
                                    summary: "Online, but trigger pending\(waited)",
                                    advice: "The Jamf agent checked in \(minutes(since: lastContact)) ago, so the network is fine, but MDM pushes aren't arriving. Try Wake. If it stays pending, restart the Mac or run `sudo launchctl kickstart -k system/com.apple.mdmclient.daemon` on it.")
            }
            return MacDiagnosis(kind: .pending,
                                summary: "Trigger not received yet\(waited)",
                                advice: "It's probably asleep, offline or can't reach Apple's push service. Try Wake.")
        }
        if let agentPolicyID {
            let installed = history.policyLogs.contains {
                $0.policyID == agentPolicyID && ($0.status ?? "").lowercased().contains("complete")
            }
            if !installed {
                return MacDiagnosis(kind: .noAgent,
                                    summary: "Checkin Now agent isn't installed",
                                    advice: "It installs at the Mac's next regular check-in, or run Set Up in Jamf Pro again.")
            }
        }
        if let delivered = history.completed.first(where: { isProfile($0) && isRecent($0) }) {
            let time = delivered.date?.formatted(date: .omitted, time: .shortened) ?? "recently"
            if agentPolicyID == nil {
                return MacDiagnosis(kind: .delivered,
                                    summary: "Trigger installed at \(time), but the agent didn't respond",
                                    advice: "Can't confirm the agent is installed (no “\(AppModel.agentPolicyName)” policy). Run Settings › Agent › Set Up in Jamf Pro, or check the Mac's /var/log/checkinnow.log.")
            }
            return MacDiagnosis(kind: .delivered,
                                summary: "Trigger installed at \(time); Jamf hasn't run yet",
                                advice: "Another Jamf policy may still be running on it. Check /var/log/checkinnow.log on the Mac, or Resend in a minute.")
        }
        return MacDiagnosis(kind: .unclear,
                            summary: "No trigger command recorded yet",
                            advice: "Jamf Pro may still be queuing it. Try Wake, then Resend.")
    }
}

/// One press of "Check In Now" and the Macs it targeted.
struct CheckinRun {
    let triggeredAt: Date
    let action: String
    let targetDescription: String
    let profileID: Int
    /// The `policyid` value sent ("default", "none" or a policy ID), kept for resends.
    let policyID: String
    /// Whether the run asked Macs to check in (run policies) and/or update inventory.
    let expectsCheckin: Bool
    let expectsInventory: Bool
    var macs: [TargetMac]
    var notFound: [String]
    var lastRefreshed: Date?
    /// When the trigger was last sent (the original send or a resend).
    var lastSentAt: Date
    /// Whether waiting Macs have been diagnosed automatically since the last send.
    var autoDiagnosed = false

    func state(of mac: TargetMac) -> MacCheckinState {
        // Allow a little clock skew between this Mac and the Jamf Pro server.
        let since = triggeredAt.addingTimeInterval(-5)
        if let report = mac.lastReport, report >= since { return .inventoryUpdated }
        if let seen = mac.lastSeen, seen >= since { return .checkedIn }
        return .waiting
    }

    var checkedInCount: Int { macs.filter { state(of: $0) >= .checkedIn }.count }
    var inventoryCount: Int { macs.filter { state(of: $0) == .inventoryUpdated }.count }
    var doneCount: Int { expectsInventory ? inventoryCount : checkedInCount }
    /// Macs that haven't responded to the trigger at all. Wake, Resend and
    /// Diagnose act on these; Macs that checked in are just finishing up.
    var waitingMacs: [TargetMac] {
        macs.filter { expectsCheckin ? state(of: $0) == .waiting : !isDone($0) }
    }
    /// Macs that checked in and are still submitting inventory.
    var updatingInventoryCount: Int {
        guard expectsCheckin && expectsInventory else { return 0 }
        return macs.filter { state(of: $0) == .checkedIn }.count
    }
    var isComplete: Bool { !macs.isEmpty && doneCount == macs.count }

    /// A Mac has finished once it has done everything the run asked for.
    func isDone(_ mac: TargetMac) -> Bool {
        let current = state(of: mac)
        return expectsInventory ? current == .inventoryUpdated : current >= .checkedIn
    }
}

@Observable
final class AppModel {
    private let defaults = UserDefaults.standard

    // MARK: Settings (persisted)

    var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    var authMethod: AuthMethod { didSet { defaults.set(authMethod.rawValue, forKey: "authMethod") } }
    var identifier: String { didSet { defaults.set(identifier, forKey: "identifier") } }
    var secret: String { didSet { Keychain.write(secret, account: "secret") } }
    var orgName: String { didSet { defaults.set(orgName, forKey: "orgName") } }
    var profileName: String { didSet { defaults.set(profileName, forKey: "profileName") } }

    // MARK: Check-in form

    var targetKind: TargetKind = .serials {
        didSet { clearPreview() }
    }
    var serialsText = "" {
        didSet { if targetKind == .serials { clearPreview() } }
    }
    var selectedGroupID: Int? {
        didSet { if targetKind == .group { clearPreview() } }
    }
    /// Run `jamf recon` after the selected policy.
    var policyUpdatesInventory = true
    var selectedPolicyID: Int?

    // MARK: State

    var groups: [ComputerGroup] = []
    var policies: [PolicySummary] = []
    /// Activity from the last 24 hours, persisted across launches.
    var log: [LogEntry] = [] {
        didSet { ActivityStore.save(log) }
    }
    /// The action currently being sent, if any.
    var runningAction: RunAction?
    var isRunning: Bool { runningAction != nil }
    var isLoadingLists = false

    /// Macs the current target resolves to, shown before running.
    var preview: [TargetMac] = []
    var previewNotFound: [String] = []
    var isLoadingPreview = false
    var hasPreview = false

    /// The most recent check-in run, refreshed while monitoring.
    var run: CheckinRun?
    var isMonitoring = false
    var isNudging = false

    /// Per-Mac explanations for Macs that are still waiting, keyed by computer ID.
    var diagnoses: [Int: MacDiagnosis] = [:]
    var isDiagnosing = false
    /// Delay before waiting Macs are diagnosed automatically.
    private let autoDiagnoseDelay: TimeInterval = 120
    private var monitorTask: Task<Void, Never>?

    /// How often and for how long to poll Jamf Pro after triggering.
    private let pollInterval: Duration = .seconds(20)
    private let monitorDuration: TimeInterval = 15 * 60

    // MARK: Jamf Pro setup

    var setupGroupID: Int?
    var setupLog: [LogEntry] = []
    var isSettingUp = false

    static let agentScriptName = "Checkin Now – Agent Setup"
    static let agentPolicyName = "Checkin Now – Install Agent"

    init() {
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        authMethod = AuthMethod(rawValue: defaults.string(forKey: "authMethod") ?? "") ?? .apiClient
        identifier = defaults.string(forKey: "identifier") ?? ""
        secret = Keychain.read("secret")
        orgName = defaults.string(forKey: "orgName") ?? ""
        profileName = defaults.string(forKey: "profileName") ?? "Checkin Now Trigger"
        log = ActivityStore.load()
    }

    var isConfigured: Bool {
        !serverURL.isEmpty && !identifier.isEmpty && !secret.isEmpty && !sanitizedOrgName.isEmpty
    }

    /// The org name with whitespace removed, matching the agent script's "no spaces" rule.
    var sanitizedOrgName: String {
        orgName.filter { !$0.isWhitespace }
    }

    /// Serial numbers parsed from the text field: separated by newlines, commas,
    /// semicolons or spaces, de-duplicated and uppercased.
    var serials: [String] {
        var seen = Set<String>()
        return serialsText
            .components(separatedBy: CharacterSet(charactersIn: ",; \t\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var hasTarget: Bool {
        targetKind == .serials ? !serials.isEmpty : selectedGroupID != nil
    }

    func canRun(_ action: RunAction) -> Bool {
        guard isConfigured, !isRunning, hasTarget else { return false }
        return action.kind != .policy || selectedPolicyID != nil
    }

    /// The Jamf Pro host name, shown in the window subtitle.
    var serverHost: String? {
        guard isConfigured else { return nil }
        return JamfClient.normalizedURL(serverURL)?.host()
    }

    /// Link to a computer's inventory record in the Jamf Pro web console.
    func jamfURL(forComputer id: Int) -> URL? {
        JamfClient.normalizedURL(serverURL)?
            .appending(path: "computers.html")
            .appending(queryItems: [URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "o", value: "r")])
    }

    private func makeClient() throws -> JamfClient {
        try JamfClient(serverURL: serverURL, auth: authMethod, identifier: identifier, secret: secret)
    }

    private func append(_ level: LogEntry.Level, _ text: String) {
        log = ActivityStore.prune(log + [LogEntry(level: level, text: text)])
    }

    private func clearPreview() {
        preview = []
        previewNotFound = []
        hasPreview = false
    }

    // MARK: Actions

    func testConnection() async -> String {
        do {
            try await makeClient().testConnection()
            return "Connected to Jamf Pro."
        } catch {
            return error.localizedDescription
        }
    }

    /// Loads computer groups and policies for the pickers.
    func loadLists() async {
        guard isConfigured, !isLoadingLists else { return }
        isLoadingLists = true
        defer { isLoadingLists = false }
        do {
            let client = try makeClient()
            groups = try await client.computerGroups()
            policies = try await client.policies()
        } catch {
            append(.error, "Couldn't load groups and policies: \(error.localizedDescription)")
        }
    }

    /// Resolves the current target into Macs, with inventory details.
    private func resolveTargets(with client: JamfClient) async throws -> (macs: [TargetMac], notFound: [String]) {
        var summaries: [ComputerSummary] = []
        var notFound: [String] = []

        switch targetKind {
        case .serials:
            for serial in serials {
                if let computer = try await client.computer(serial: serial) {
                    summaries.append(computer)
                } else {
                    notFound.append(serial)
                }
            }
        case .group:
            guard let groupID = selectedGroupID else { return ([], []) }
            summaries = try await client.groupMembers(groupID: groupID)
        }

        var macs = summaries.map(TargetMac.init)
        let statuses = try await client.computerStatuses(ids: macs.map(\.id))
        let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in macs.indices {
            if let status = byID[macs[index].id] { macs[index].apply(status) }
        }
        macs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (macs, notFound)
    }

    /// Shows which Macs the current target resolves to (group members or serial lookups).
    func loadPreview() async {
        guard isConfigured, !isLoadingPreview else { return }
        let hasTarget = targetKind == .serials ? !serials.isEmpty : selectedGroupID != nil
        guard hasTarget else { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let resolved = try await resolveTargets(with: makeClient())
            preview = resolved.macs
            previewNotFound = resolved.notFound
            hasPreview = true
            if var current = run {
                let fresh = Dictionary(resolved.macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in current.macs.indices {
                    if let mac = fresh[current.macs[index].id] { current.macs[index] = mac }
                }
                run = current
            }
        } catch {
            append(.error, "Couldn't look up targets: \(error.localizedDescription)")
        }
    }

    /// Resolves the targets, then creates or updates the trigger profile scoped
    /// to them so Jamf Pro pushes it immediately over APNs, then watches the
    /// Macs' inventory until they've checked in.
    func forceCheckin(_ runAction: RunAction) async {
        guard canRun(runAction) else { return }
        runningAction = runAction
        defer { runningAction = nil }
        let checkinKind = runAction.kind
        stopMonitoring()

        do {
            let client = try makeClient()
            let (macs, notFound) = try await resolveTargets(with: client)
            preview = macs
            previewNotFound = notFound
            hasPreview = true

            for serial in notFound {
                append(.warning, "No computer in Jamf Pro with serial \(serial)")
            }

            var computerIDs: [Int] = []
            var groupIDs: [Int] = []
            let targetDescription: String
            switch targetKind {
            case .serials:
                guard !macs.isEmpty else {
                    append(.error, "None of the serial numbers matched a computer. Nothing was sent.")
                    return
                }
                computerIDs = macs.map(\.id)
                targetDescription = macs.count == 1 ? macs[0].name : "\(macs.count) Macs"
            case .group:
                guard let groupID = selectedGroupID else { return }
                groupIDs = [groupID]
                let groupName = groups.first { $0.id == groupID }?.name ?? "ID \(groupID)"
                targetDescription = "group “\(groupName)” (\(macs.count) Mac\(macs.count == 1 ? "" : "s"))"
                if macs.isEmpty {
                    append(.warning, "Group “\(groupName)” has no members right now.")
                }
            }

            let updateInventory = checkinKind == .inventory || runAction.updateInventory
            let policyID: String
            var action: String
            switch checkinKind {
            case .checkin:
                policyID = "default"
                action = "Check In"
            case .inventory:
                policyID = "none"
                action = "Update Inventory"
            case .policy:
                policyID = String(selectedPolicyID ?? 0)
                action = "Run Policy “\(policies.first { $0.id == selectedPolicyID }?.name ?? policyID)” (ID \(policyID))"
            }
            if checkinKind != .inventory && updateInventory {
                action += " + Update Inventory"
            }

            let xml = try TriggerProfile.xml(
                name: profileName,
                orgName: sanitizedOrgName,
                policyID: policyID,
                updateInventory: updateInventory,
                computerIDs: computerIDs,
                groupIDs: groupIDs
            )
            let triggeredAt = Date()
            let existingID = try await client.configurationProfileID(named: profileName)
            let profileID = try await client.saveConfigurationProfile(id: existingID, xml: xml)

            append(.success, "\(existingID == nil ? "Created" : "Updated") profile “\(profileName)” (ID \(profileID)). Sent \(action) to \(targetDescription).")

            run = CheckinRun(
                triggeredAt: triggeredAt,
                action: action,
                targetDescription: targetDescription,
                profileID: profileID,
                policyID: policyID,
                expectsCheckin: checkinKind != .inventory,
                expectsInventory: updateInventory,
                macs: macs,
                notFound: notFound,
                lastRefreshed: Date(),
                lastSentAt: triggeredAt
            )
            diagnoses = [:]
            startMonitoring()
        } catch {
            append(.error, error.localizedDescription)
        }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        guard run?.macs.isEmpty == false else { return }
        monitorTask?.cancel()
        isMonitoring = true
        let deadline = Date().addingTimeInterval(monitorDuration)
        monitorTask = Task { [weak self] in
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(20))
                guard let self, !Task.isCancelled else { break }
                await self.refreshRun()
                if self.run?.isComplete == true { break }
                if let run = self.run, !run.autoDiagnosed,
                   Date().timeIntervalSince(run.lastSentAt) >= self.autoDiagnoseDelay {
                    self.run?.autoDiagnosed = true
                    await self.diagnoseWaitingMacs()
                }
            }
            guard let self else { return }
            self.isMonitoring = false
            if let run = self.run {
                self.append(run.isComplete ? .success : .info,
                            "\(run.doneCount) of \(run.macs.count) Macs finished “\(run.action)”.")
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    /// Sends an MDM blank push to the Macs that haven't finished, prompting them
    /// to contact Apple's push service and pick up the pending trigger profile.
    func wakeWaitingMacs() async {
        guard let run, !run.waitingMacs.isEmpty, !isNudging else { return }
        isNudging = true
        defer { isNudging = false }
        let waiting = run.waitingMacs
        do {
            try await makeClient().sendBlankPush(computerIDs: waiting.map(\.id), managementIDs: waiting.compactMap(\.managementID))
            append(.info, "Sent a wake-up push to \(Self.describe(waiting))")
        } catch {
            append(.error, "Couldn't send wake-up push: \(error.localizedDescription)")
        }
    }

    /// Re-sends the trigger profile (with a fresh payload) to only the Macs that
    /// haven't finished, wakes them, and keeps watching.
    func resendToWaitingMacs() async {
        guard let run, !run.waitingMacs.isEmpty, !isNudging else { return }
        isNudging = true
        defer { isNudging = false }
        let waiting = run.waitingMacs
        do {
            let client = try makeClient()
            let xml = try TriggerProfile.xml(
                name: profileName,
                orgName: sanitizedOrgName,
                policyID: run.policyID,
                updateInventory: run.expectsInventory,
                computerIDs: waiting.map(\.id),
                groupIDs: []
            )
            _ = try await client.saveConfigurationProfile(id: run.profileID, xml: xml)
            self.run?.lastSentAt = Date()
            self.run?.autoDiagnosed = false
            for mac in waiting { diagnoses[mac.id] = nil }
            append(.success, "Resent “\(run.action)” to \(Self.describe(waiting))")
            // The wake-up push is best effort; the profile change already triggers a push.
            try? await client.sendBlankPush(computerIDs: waiting.map(\.id), managementIDs: waiting.compactMap(\.managementID))
            startMonitoring()
        } catch {
            append(.error, "Couldn't resend: \(error.localizedDescription)")
        }
    }

    /// Reads each waiting Mac's Jamf Pro history and records why it hasn't finished.
    func diagnoseWaitingMacs() async {
        guard let run, !isDiagnosing else { return }
        let waiting = Array(run.waitingMacs.prefix(25))
        guard !waiting.isEmpty else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }

        do {
            let client = try makeClient()
            // If the agent was installed some other way, the policy won't exist and
            // the agent check is skipped.
            let agentPolicyID = try? await client.policyID(named: Self.agentPolicyName)
            for mac in waiting {
                do {
                    let history = try await client.computerHistory(id: mac.id)
                    let diagnosis = MacDiagnosis.make(history: history, since: run.lastSentAt, agentPolicyID: agentPolicyID ?? nil,
                                                       lastContact: mac.lastSeen)
                    diagnoses[mac.id] = diagnosis
                    append(.warning, "\(mac.name): \(diagnosis.summary)")
                } catch {
                    diagnoses[mac.id] = MacDiagnosis(kind: .unknown, summary: "Couldn't read history",
                                                     advice: error.localizedDescription)
                }
            }
            if run.waitingMacs.count > waiting.count {
                append(.info, "Diagnosed the first \(waiting.count) of \(run.waitingMacs.count) waiting Macs")
            }
        } catch {
            append(.error, "Couldn't diagnose: \(error.localizedDescription)")
        }
    }

    private static func describe(_ macs: [TargetMac]) -> String {
        macs.count == 1 ? macs[0].name : "\(macs.count) Macs"
    }

    /// Re-reads inventory times for the Macs in the current run.
    func refreshRun() async {
        guard run != nil || hasPreview else { return }
        // Refresh every Mac shown anywhere (targets and the run) in one request.
        let ids = Array(Set((run?.macs.map(\.id) ?? []) + preview.map(\.id)))
        do {
            let statuses = try await makeClient().computerStatuses(ids: ids)
            apply(statuses)
        } catch {
            append(.warning, "Couldn't refresh status: \(error.localizedDescription)")
        }
    }

    /// Updates the targets list and the current run from fresh inventory, so every
    /// table and the sidebar show the same details. Logs Macs that just finished.
    private func apply(_ statuses: [ComputerStatus]) {
        let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in preview.indices {
            if let status = byID[preview[index].id] { preview[index].apply(status) }
        }
        guard var current = run else { return }
        for index in current.macs.indices {
            guard let status = byID[current.macs[index].id] else { continue }
            let before = current.state(of: current.macs[index])
            current.macs[index].apply(status)
            let after = current.state(of: current.macs[index])
            if after > before {
                let mac = current.macs[index]
                append(.success, after == .inventoryUpdated
                       ? "\(mac.name) updated inventory"
                       : "\(mac.name) checked in")
            }
        }
        current.lastRefreshed = Date()
        run = current
    }

    // MARK: Jamf Pro setup

    /// Uploads the agent setup script, creates a policy that installs it once per
    /// computer, and creates the (unscoped) trigger profile if it doesn't exist.
    func setUpJamfPro() async {
        guard isConfigured, !isSettingUp else { return }
        isSettingUp = true
        defer { isSettingUp = false }
        setupLog = []

        func note(_ level: LogEntry.Level, _ text: String) {
            setupLog.append(LogEntry(level: level, text: text))
        }

        do {
            let client = try makeClient()

            let existingScript = try await client.scriptID(named: Self.agentScriptName)
            let scriptID = try await client.saveScript(
                id: existingScript,
                name: Self.agentScriptName,
                notes: "Installs the Checkin Now agent (LaunchDaemon watching com.\(sanitizedOrgName).checkin). Managed by Checkin Now.",
                contents: WatcherScript.script(orgName: sanitizedOrgName)
            )
            note(.success, "\(existingScript == nil ? "Created" : "Updated") script “\(Self.agentScriptName)” (ID \(scriptID))")

            let existingPolicy = try await client.policyID(named: Self.agentPolicyName)
            let policyID = try await client.saveInstallPolicy(
                id: existingPolicy,
                name: Self.agentPolicyName,
                scriptID: scriptID,
                groupID: setupGroupID
            )
            let scope = setupGroupID.flatMap { id in groups.first { $0.id == id }?.name }.map { "group “\($0)”" } ?? "all computers"
            if existingPolicy != nil {
                // Re-run the (idempotent) installer so Macs pick up the latest agent.
                try await client.flushPolicyLogs(policyID: policyID)
                note(.info, "Flushed policy logs so Macs reinstall the latest agent at next check-in")
            }
            note(.success, "\(existingPolicy == nil ? "Created" : "Updated") policy “\(Self.agentPolicyName)” (ID \(policyID)), once per computer, scoped to \(scope)")

            if let profileID = try await client.configurationProfileID(named: profileName) {
                note(.info, "Trigger profile “\(profileName)” already exists (ID \(profileID)); left unchanged")
            } else {
                let xml = try TriggerProfile.xml(name: profileName, orgName: sanitizedOrgName, policyID: "default", updateInventory: true, computerIDs: [], groupIDs: [])
                let profileID = try await client.saveConfigurationProfile(id: nil, xml: xml)
                note(.success, "Created trigger profile “\(profileName)” (ID \(profileID)) with no scope")
            }

            note(.info, "Macs install the agent at their next check-in. You can then use Check In Now.")
            policies = try await client.policies()
        } catch {
            note(.error, error.localizedDescription)
        }
    }
}
