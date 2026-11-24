import Foundation

/// How the app authenticates against Jamf Pro.
enum AuthMethod: String, CaseIterable, Identifiable {
    case apiClient
    case userAccount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API Client"
        case .userAccount: "User Account"
        }
    }
}

struct JamfError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ComputerGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let isSmart: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isSmart = "is_smart"
    }
}

struct PolicySummary: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct ComputerSummary: Hashable {
    let id: Int
    let name: String
    let serial: String
}

/// Inventory details used to show whether a Mac has checked in.
struct ComputerStatus: Hashable {
    let id: Int
    let name: String
    let serial: String
    let model: String?
    let osVersion: String?
    let lastContact: Date?
    let lastReport: Date?
    /// MDM management ID, needed for Jamf Pro API MDM commands.
    let managementID: String?
}

/// MDM command and policy history for one computer, used to explain why a Mac
/// hasn't checked in.
struct ComputerHistory {
    struct Command {
        let name: String
        let date: Date?
        let status: String?
    }

    struct PolicyLog {
        let policyID: Int?
        let policyName: String
        let date: Date?
        let status: String?
    }

    let pending: [Command]
    let completed: [Command]
    let failed: [Command]
    let policyLogs: [PolicyLog]
}

extension String {
    /// Escapes text for inclusion in Classic API XML bodies.
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Thin wrapper around the Jamf Pro Classic and Jamf Pro APIs, covering only
/// the endpoints Checkin Now needs.
final class JamfClient {
    let baseURL: URL
    private let auth: AuthMethod
    private let identifier: String
    private let secret: String
    private let session = URLSession(configuration: .ephemeral)

    private var token: String?
    private var tokenExpiry = Date.distantPast

    init(serverURL: String, auth: AuthMethod, identifier: String, secret: String) throws {
        guard let url = Self.normalizedURL(serverURL) else {
            throw JamfError(message: "The Jamf Pro URL isn't valid. Set it in Settings.")
        }
        guard !identifier.isEmpty, !secret.isEmpty else {
            throw JamfError(message: "Jamf Pro credentials are missing. Set them in Settings.")
        }
        self.baseURL = url
        self.auth = auth
        self.identifier = identifier
        self.secret = secret
    }

    /// Trims whitespace and trailing slashes and adds https:// when no scheme is given.
    static func normalizedURL(_ serverURL: String) -> URL? {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host() != nil else { return nil }
        return url
    }

    // MARK: - Authentication

    /// Returns a cached bearer token, fetching a new one when it's close to expiring.
    private func bearerToken() async throws -> String {
        if let token, tokenExpiry > Date().addingTimeInterval(30) { return token }

        var request: URLRequest
        switch auth {
        case .apiClient:
            request = URLRequest(url: baseURL.appending(path: "api/oauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = [
                ("grant_type", "client_credentials"),
                ("client_id", identifier),
                ("client_secret", secret),
            ]
            request.httpBody = form
                .map { "\($0.0)=\(Self.formEncode($0.1))" }
                .joined(separator: "&")
                .data(using: .utf8)
        case .userAccount:
            request = URLRequest(url: baseURL.appending(path: "api/v1/auth/token"))
            request.httpMethod = "POST"
            let basic = Data("\(identifier):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct TokenResponse: Decodable {
            let access_token: String?
            let expires_in: Double?
            let token: String?
        }
        let data = try await send(request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let newToken = response.access_token ?? response.token else {
            throw JamfError(message: "Jamf Pro didn't return an access token.")
        }
        token = newToken
        // User tokens last 30 minutes by default; refresh well before that.
        tokenExpiry = Date().addingTimeInterval(response.expires_in ?? 20 * 60)
        return newToken
    }

    /// Strict percent-encoding (RFC 3986 unreserved characters only) so values
    /// containing `+`, `&`, `=` or parentheses survive intact.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Requests

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfError(message: "No response from Jamf Pro.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }

    private func authorizedRequest(_ path: String, query: [(String, String)] = [], method: String = "GET") async throws -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
                .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
                .joined(separator: "&")
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func getJSON<T: Decodable>(_ type: T.Type, path: String, query: [(String, String)] = []) async throws -> T {
        let data = try await send(try await authorizedRequest(path, query: query))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendXML(_ xml: String, path: String, method: String) async throws -> Data {
        var request = try await authorizedRequest(path, method: method)
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(xml.utf8)
        return try await send(request)
    }

    /// Creates (POST to id/0) or updates (PUT to id/N) a Classic API object and returns its ID.
    private func saveClassic(_ resource: String, id: Int?, xml: String) async throws -> Int {
        let data = try await sendXML(xml, path: "JSSResource/\(resource)/id/\(id ?? 0)", method: id == nil ? "POST" : "PUT")
        if let id { return id }
        // The Classic API replies with <object><id>N</id></object>.
        let body = String(decoding: data, as: UTF8.self)
        guard let range = body.range(of: #"<id>(\d+)</id>"#, options: .regularExpression),
              let newID = Int(body[range].filter(\.isNumber)) else {
            throw JamfError(message: "Jamf Pro created the \(resource) item but didn't return its ID.")
        }
        return newID
    }

    // MARK: - Endpoints

    /// Verifies the credentials by fetching a token.
    func testConnection() async throws {
        token = nil
        _ = try await bearerToken()
    }

    func computerGroups() async throws -> [ComputerGroup] {
        struct Response: Decodable { let computer_groups: [ComputerGroup] }
        return try await getJSON(Response.self, path: "JSSResource/computergroups").computer_groups
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Current members of a static or smart computer group.
    func groupMembers(groupID: Int) async throws -> [ComputerSummary] {
        struct Response: Decodable {
            struct Group: Decodable {
                struct Member: Decodable {
                    let id: Int
                    let name: String
                    let serial_number: String?
                }
                let computers: [Member]?
            }
            let computer_group: Group
        }
        return try await getJSON(Response.self, path: "JSSResource/computergroups/id/\(groupID)")
            .computer_group.computers?
            .map { ComputerSummary(id: $0.id, name: $0.name, serial: $0.serial_number ?? "") } ?? []
    }

    func policies() async throws -> [PolicySummary] {
        struct Response: Decodable { let policies: [PolicySummary] }
        return try await getJSON(Response.self, path: "JSSResource/policies").policies
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Looks up a computer by serial number. Returns nil when Jamf Pro has no match.
    func computer(serial: String) async throws -> ComputerSummary? {
        struct Response: Decodable {
            struct Computer: Decodable {
                struct General: Decodable {
                    let id: Int
                    let name: String
                    let serial_number: String
                }
                let general: General
            }
            let computer: Computer
        }
        let encoded = serial.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serial
        do {
            let general = try await getJSON(Response.self, path: "JSSResource/computers/serialnumber/\(encoded)/subset/General")
                .computer.general
            return ComputerSummary(id: general.id, name: general.name, serial: general.serial_number)
        } catch let error as HTTPStatusError where error.status == 404 {
            return nil
        }
    }

    /// Fetches last check-in and inventory times for many computers, 100 per request,
    /// using the Jamf Pro API inventory endpoint.
    func computerStatuses(ids: [Int]) async throws -> [ComputerStatus] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct General: Decodable {
                    let name: String?
                    let managementId: String?
                    let lastContactTime: String?
                    let reportDate: String?
                    let lastReportDate: String?
                }
                struct Hardware: Decodable {
                    let serialNumber: String?
                    let model: String?
                }
                struct OperatingSystem: Decodable {
                    let version: String?
                }
                let id: String
                let general: General?
                let hardware: Hardware?
                let operatingSystem: OperatingSystem?
            }
            let results: [Item]
        }

        var statuses: [ComputerStatus] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let response = try await getJSON(Response.self, path: "api/v1/computers-inventory", query: [
                ("section", "GENERAL"),
                ("section", "HARDWARE"),
                ("section", "OPERATING_SYSTEM"),
                ("page", "0"),
                ("page-size", "100"),
                ("filter", "id=in=(\(batch.map(String.init).joined(separator: ",")))"),
            ])
            statuses += response.results.compactMap { item in
                guard let id = Int(item.id) else { return nil }
                return ComputerStatus(
                    id: id,
                    name: item.general?.name ?? "Computer \(id)",
                    serial: item.hardware?.serialNumber ?? "",
                    model: item.hardware?.model,
                    osVersion: item.operatingSystem?.version,
                    lastContact: Self.parseDate(item.general?.lastContactTime),
                    lastReport: Self.parseDate(item.general?.reportDate ?? item.general?.lastReportDate),
                    managementID: item.general?.managementId
                )
            }
        }
        return statuses
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Configuration profiles, scripts and policies

    /// Finds a macOS configuration profile ID by exact name.
    func configurationProfileID(named name: String) async throws -> Int? {
        struct Response: Decodable {
            struct Profile: Decodable { let id: Int; let name: String }
            let os_x_configuration_profiles: [Profile]
        }
        return try await getJSON(Response.self, path: "JSSResource/osxconfigurationprofiles")
            .os_x_configuration_profiles.first { $0.name == name }?.id
    }

    /// Creates (when `id` is nil) or updates a macOS configuration profile. Returns its ID.
    func saveConfigurationProfile(id: Int?, xml: String) async throws -> Int {
        try await saveClassic("osxconfigurationprofiles", id: id, xml: xml)
    }

    func scriptID(named name: String) async throws -> Int? {
        struct Response: Decodable {
            struct Script: Decodable { let id: Int; let name: String }
            let scripts: [Script]
        }
        return try await getJSON(Response.self, path: "JSSResource/scripts")
            .scripts.first { $0.name == name }?.id
    }

    /// Creates or updates a script in Jamf Pro. Returns its ID.
    func saveScript(id: Int?, name: String, notes: String, contents: String) async throws -> Int {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <script>
          <name>\(name.xmlEscaped)</name>
          <info>\(notes.xmlEscaped)</info>
          <notes>\(notes.xmlEscaped)</notes>
          <priority>After</priority>
          <script_contents>\(contents.xmlEscaped)</script_contents>
        </script>
        """
        return try await saveClassic("scripts", id: id, xml: xml)
    }

    /// Reads a computer's MDM command history and policy logs (Classic API).
    func computerHistory(id: Int) async throws -> ComputerHistory {
        struct Response: Decodable {
            struct History: Decodable {
                struct Commands: Decodable {
                    let completed: [Item]?
                    let pending: [Item]?
                    let failed: [Item]?
                }
                struct Item: Decodable {
                    let name: String?
                    let status: String?
                    let issued_epoch: Double?
                    let completed_epoch: Double?
                    let failed_epoch: Double?
                }
                struct Log: Decodable {
                    let policy_id: Int?
                    let policy_name: String?
                    let date_completed_epoch: Double?
                    let status: String?
                }
                let commands: Commands?
                let policy_logs: [Log]?
            }
            let computer_history: History
        }

        // Epoch values from the Classic API are in milliseconds.
        func date(_ epoch: Double?) -> Date? {
            guard let epoch, epoch > 0 else { return nil }
            return Date(timeIntervalSince1970: epoch / 1000)
        }
        func commands(_ items: [Response.History.Item]?, dateKey: (Response.History.Item) -> Double?) -> [ComputerHistory.Command] {
            (items ?? []).map { ComputerHistory.Command(name: $0.name ?? "", date: date(dateKey($0)), status: $0.status) }
        }

        let history = try await getJSON(Response.self, path: "JSSResource/computerhistory/id/\(id)/subset/Commands&PolicyLogs")
            .computer_history
        return ComputerHistory(
            pending: commands(history.commands?.pending) { $0.issued_epoch },
            completed: commands(history.commands?.completed) { $0.completed_epoch },
            failed: commands(history.commands?.failed) { $0.failed_epoch ?? $0.issued_epoch },
            policyLogs: (history.policy_logs ?? []).map {
                ComputerHistory.PolicyLog(policyID: $0.policy_id, policyName: $0.policy_name ?? "",
                                          date: date($0.date_completed_epoch), status: $0.status)
            }
        )
    }

    /// Sends an MDM blank push, which makes the Macs check in with MDM and
    /// receive any pending commands (such as the trigger profile).
    ///
    /// Uses the Jamf Pro API (`/api/v2/mdm/blank-push`, by management ID), and
    /// falls back to the Classic API one computer at a time on older servers.
    func sendBlankPush(computerIDs: [Int], managementIDs: [String]) async throws {
        if !managementIDs.isEmpty {
            do {
                var request = try await authorizedRequest("api/v2/mdm/blank-push", method: "POST")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["clientManagementIds": managementIDs])
                try await send(request)
                return
            } catch let error as HTTPStatusError where error.status == 404 || error.status == 405 {
                // Older Jamf Pro without the endpoint: fall through to the Classic API.
            }
        }
        for id in computerIDs {
            try await send(try await authorizedRequest("JSSResource/computercommands/command/BlankPush/id/\(id)", method: "POST"))
        }
    }

    /// Clears a policy's logs so every scoped Mac runs it again at next check-in.
    func flushPolicyLogs(policyID: Int) async throws {
        try await send(try await authorizedRequest("JSSResource/logflush/policy/id/\(policyID)/interval/Zero+Days", method: "DELETE"))
    }

    func policyID(named name: String) async throws -> Int? {
        try await policies().first { $0.name == name }?.id
    }

    /// Creates or updates a policy that runs `scriptID` once per computer at
    /// recurring check-in and enrollment, scoped to all computers or one group.
    func saveInstallPolicy(id: Int?, name: String, scriptID: Int, groupID: Int?) async throws -> Int {
        let scope = if let groupID {
            "<all_computers>false</all_computers><computer_groups><computer_group><id>\(groupID)</id></computer_group></computer_groups>"
        } else {
            "<all_computers>true</all_computers><computer_groups/>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <policy>
          <general>
            <name>\(name.xmlEscaped)</name>
            <enabled>true</enabled>
            <trigger_checkin>true</trigger_checkin>
            <trigger_enrollment_complete>true</trigger_enrollment_complete>
            <frequency>Once per computer</frequency>
          </general>
          <scope>\(scope)</scope>
          <scripts>
            <size>1</size>
            <script><id>\(scriptID)</id><priority>After</priority></script>
          </scripts>
        </policy>
        """
        return try await saveClassic("policies", id: id, xml: xml)
    }
}

struct HTTPStatusError: LocalizedError {
    let status: Int
    let body: String

    /// The response body with any HTML tags removed (Classic API errors are HTML pages).
    private var readableBody: String {
        body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    var errorDescription: String? {
        switch status {
        case 401: "Jamf Pro rejected the credentials (401)."
        case 403: "The Jamf Pro account lacks the required privileges (403)."
        case 404: "Not found in Jamf Pro (404)."
        default: "Jamf Pro returned HTTP \(status). \(readableBody)"
        }
    }
}
