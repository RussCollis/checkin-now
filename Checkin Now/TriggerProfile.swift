import Foundation

/// Builds the Classic API XML for the Checkin Now trigger configuration profile.
///
/// The profile delivers the managed preference domain `com.<org>.checkin` with a
/// `policyid` key. The Checkin Now agent (LaunchDaemon) on each Mac watches
/// `/Library/Managed Preferences/com.<org>.checkin.plist` and runs
/// `jamf policy` (or `jamf policy -id N`) whenever that file changes.
enum TriggerProfile {
    static func domain(orgName: String) -> String { "com.\(orgName).checkin" }

    /// - Parameters:
    ///   - policyID: `"default"` for a normal check-in, a numeric policy ID, or `"none"`.
    ///   - updateInventory: Whether the agent runs `jamf recon` afterwards.
    static func xml(
        name: String,
        orgName: String,
        policyID: String,
        updateInventory: Bool,
        computerIDs: [Int],
        groupIDs: [Int]
    ) throws -> String {
        let domain = domain(orgName: orgName)
        let identifier = "com.russcollis.CheckinNow.trigger.\(orgName)"

        // `triggered` changes on every run so the managed preferences file is
        // always rewritten, which is what fires the LaunchDaemon's WatchPaths.
        let settings: [String: Any] = [
            "policyid": policyID,
            "recon": updateInventory ? "true" : "false",
            "triggered": ISO8601DateFormatter().string(from: Date()) + " " + UUID().uuidString,
        ]
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).\(domain)",
            "PayloadUUID": UUID().uuidString,
            "PayloadEnabled": true,
            "PayloadDisplayName": "Checkin Now Trigger",
            "PayloadContent": [
                domain: ["Forced": [["mcx_preference_settings": settings]]],
            ],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": name,
            "PayloadScope": "System",
            "PayloadOrganization": "Checkin Now",
            "PayloadDescription": "Triggers an immediate Jamf Pro check-in. Managed by Checkin Now.",
            "PayloadContent": [payload],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let plist = String(decoding: plistData, as: UTF8.self)

        let computers = computerIDs.map { "<computer><id>\($0)</id></computer>" }.joined()
        let groups = groupIDs.map { "<computer_group><id>\($0)</id></computer_group>" }.joined()

        // Scope is replaced on every run so only the current targets receive the trigger.
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <os_x_configuration_profile>
          <general>
            <name>\(name.xmlEscaped)</name>
            <description>Managed by Checkin Now. Triggers an immediate Jamf Pro check-in through the Checkin Now agent. Scope is replaced on every run.</description>
            <distribution_method>Install Automatically</distribution_method>
            <user_removable>false</user_removable>
            <level>computer</level>
            <redeploy_on_update>All</redeploy_on_update>
            <payloads>\(plist.xmlEscaped)</payloads>
          </general>
          <scope>
            <all_computers>false</all_computers>
            <computers>\(computers)</computers>
            <computer_groups>\(groups)</computer_groups>
          </scope>
        </os_x_configuration_profile>
        """
    }
}
