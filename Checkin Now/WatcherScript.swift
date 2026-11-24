import Foundation

/// Generates the Checkin Now agent setup script (derived from
/// jamf-checkin-watcher's checkInWatcherCreator.sh) with the org name filled in.
/// Deploy it to Macs once, e.g. via Settings › Set Up in Jamf Pro, so they react
/// to the trigger profile. File paths and the LaunchDaemon label are unchanged
/// from jamf-checkin-watcher so existing installs keep working.
enum WatcherScript {
    static func script(orgName: String) -> String {
        #"""
        #!/bin/zsh

        ## Checkin Now – Agent Setup
        ## © 2026 Russell Collis · MIT License
        ## Installs the Checkin Now agent: a LaunchDaemon that runs a Jamf Pro
        ## check-in whenever the Checkin Now trigger profile is delivered or updated.
        ## Paths and labels match jamf-checkin-watcher, so existing installs are upgraded in place.
        ## Derived from jamf-checkin-watcher © 2021 Buoy Health, Inc. (Apache License 2.0).

        orgName="\#(orgName)"

        if [[ ! $orgName ]]; then echo "Org name not set, exiting!"; exit 1; fi

        mkdir -p "/Library/Application Support/$orgName"

        cat << EOF > "/Library/Application Support/$orgName/checkin.sh"
        #!/bin/bash
        shopt -s extglob

        ## Checkin Now agent v4. Keys in the trigger profile:
        ##   policyid: "default" = jamf policy, digits = jamf policy -id N, "none" = skip
        ##   recon:    "false" = skip jamf recon (anything else, or missing, runs it)
        ## Each trigger is logged to /var/log/checkinnow.log.
        prefs="/Library/Managed Preferences/com.$orgName.checkin.plist"
        log="/var/log/checkinnow.log"

        if [[ -e "\$prefs" ]]; then
        	policyid=\$(defaults read "\$prefs" policyid 2>/dev/null)
        	recon=\$(defaults read "\$prefs" recon 2>/dev/null)
        	triggered=\$(defaults read "\$prefs" triggered 2>/dev/null)
        	echo "\$(date '+%Y-%m-%d %H:%M:%S') trigger \$triggered policyid=\$policyid recon=\$recon" >> "\$log"
        	case "\$policyid" in
        		+([[:digit:]]) )
        			/usr/local/bin/jamf policy -id \$policyid
        			;;
        		default)
        			/usr/local/bin/jamf policy
        			;;
        		*)
        			;;
        	esac
        	echo "\$(date '+%Y-%m-%d %H:%M:%S') policy step finished (exit \$?)" >> "\$log"

        	if [[ "\$recon" != "false" ]]; then
        		/usr/local/bin/jamf recon
        		echo "\$(date '+%Y-%m-%d %H:%M:%S') jamf recon finished (exit \$?)" >> "\$log"
        	fi
        fi
        EOF

        chmod +x "/Library/Application Support/$orgName/checkin.sh"

        cat << EOF > "/Library/LaunchDaemons/com.$orgName.checkinwatcher.plist"
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>Label</key>
        	<string>com.$orgName.checkinwatcher</string>
        	<key>ProgramArguments</key>
        	<array>
        		<string>sh</string>
        		<string>/Library/Application Support/$orgName/checkin.sh</string>
        	</array>
        	<key>WatchPaths</key>
        	<array>
        		<string>/Library/Managed Preferences/com.$orgName.checkin.plist</string>
        	</array>
        </dict>
        </plist>
        EOF

        chown root:wheel "/Library/LaunchDaemons/com.$orgName.checkinwatcher.plist"
        chmod 644 "/Library/LaunchDaemons/com.$orgName.checkinwatcher.plist"
        launchctl bootout system "/Library/LaunchDaemons/com.$orgName.checkinwatcher.plist" 2>/dev/null
        launchctl bootstrap system "/Library/LaunchDaemons/com.$orgName.checkinwatcher.plist"

        """#
    }
}
