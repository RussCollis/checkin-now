<p align="center"><img src="icon.png" width="128" alt="Checkin Now icon"></p>

# Checkin Now

A macOS app that forces Jamf Pro–managed Macs to check in immediately, by serial number or computer group, and shows each Mac checking in live.

**Version:** 0.6.9
**Owner:** Russell Collis

## Features
- Target one or more serial numbers, or any static/smart computer group
- Lists group members (or looked-up serials) with model, macOS version, last check-in and last inventory
- One-click actions: **Check In + Update Inventory** (⌘↩), **Check In**, **Update Inventory**, and **Run Policy** (optionally followed by an inventory update)
- Sidebar progress list with **Wake** (MDM blank push) and **Resend** (trigger only the Macs still waiting)
- **Diagnose** waiting Macs from their Jamf Pro MDM command history and policy logs: trigger not received yet, Mac online but MDM not responding, MDM queue stuck, deferred (NotNow), failed, agent not installed, or delivered but Jamf hasn't run. Runs automatically after 2 minutes
- Live results: watches Jamf Pro after triggering and marks each Mac **Waiting → Checked In → Done** (inventory updated)
- One-click **Set Up in Jamf Pro**: uploads the agent script, creates the install policy, and creates the trigger profile
- Activity log keeps the last 24 hours across launches, grouped by hour, with an Issues filter, search and copy
- Open any Mac in Jamf Pro or copy serials from the results table
- API Client (OAuth) or user account authentication; secret stored in the Keychain

## How it works
Jamf Pro normally only lets Macs check in for policies every 15 minutes. Checkin Now creates or updates a
configuration profile (default name **Checkin Now Trigger**) carrying the managed preference domain
`com.<orgName>.checkin` with a `policyid` key (`default`, a policy ID, or `none`) and a `recon` key
(`true`/`false`), and scopes it to your targets.
Jamf Pro pushes it over APNs right away.

On each Mac, the **Checkin Now agent** (a LaunchDaemon) watches
`/Library/Managed Preferences/com.<orgName>.checkin.plist` and runs `jamf policy` (or `jamf policy -id N`),
then `jamf recon` unless `recon` is `false`, as soon as the profile lands. Each trigger is logged on the Mac
to `/var/log/checkinnow.log`. Older jamf-checkin-watcher agents
ignore `recon` and always update inventory; Inventory-only runs work with them too. Checkin Now then polls Jamf Pro every 20 seconds
(for up to 15 minutes) and compares each Mac's last check-in and inventory times with the trigger time.

Every run replaces the profile's scope with the current targets and changes the payload, so the profile is
redeployed and the agent fires again. The agent uses the same paths and LaunchDaemon label as
jamf-checkin-watcher, so existing installs keep working.

## Getting started
1. Open `Checkin Now.xcodeproj` in Xcode and build the **Checkin Now** scheme (macOS 27.2+).
2. In Jamf Pro, create an API role/client with: Read Computers, Read Computer Groups, and
   Create/Read/Update Policies, Scripts and macOS Configuration Profiles, plus permission to send
   blank push commands to computers (used by **Wake**).
3. In **Checkin Now › Settings**, enter the server URL, credentials, and your org name (no spaces).
4. Under **Setup**, choose where to install the agent (All Computers or a group) and click
   **Set Up in Jamf Pro**. This creates:
   - Script **Checkin Now – Agent Setup**
   - Policy **Checkin Now – Install Agent** (once per computer, at recurring check-in and enrollment)
   - Configuration profile **Checkin Now Trigger** (unscoped), if it doesn't exist yet

   Running it again updates the script and flushes the policy logs, so Macs reinstall the latest agent.
   Macs install the agent at their next check-in. You can also copy or save the script from the **Script** menu.

## Usage
1. Choose **Serial Numbers** (then **Look Up**) or **Computer Group**. The **Targets** tab lists the Macs.
2. Click **Check In + Update Inventory** (⌘↩), **Check In**, **Update Inventory**, or choose a policy and click **Run Policy**.
3. Watch progress in the sidebar and the **Last Run** tab. If a Mac stays on Waiting, its reason appears under it
   (or click **Diagnose**); then use **Wake** or **Resend**.
   Double-click a Mac to open it in Jamf Pro.

## License
MIT © 2026 Russell Collis — see [LICENSE](LICENSE).

The agent setup script is derived from [jamf-checkin-watcher](https://github.com/mhrono/jamf-checkin-watcher)
© 2021 Buoy Health, Inc., licensed under the Apache License 2.0 — see [NOTICE](NOTICE).
