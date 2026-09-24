#!/bin/bash
# Remove every trace of lidswitch and restore normal lid sleep. Run: sudo ./uninstall.sh
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
TARGET_USER="${SUDO_USER:?run via sudo from your own account}"
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
LABEL=com.arhanbarve.lidswitch

launchctl bootout "gui/$TARGET_UID/$LABEL" 2>/dev/null
launchctl bootout "system/$LABEL.bootoff" 2>/dev/null
rm -f "$TARGET_HOME/Library/LaunchAgents/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.bootoff.plist" /etc/sudoers.d/lidswitch
rm -rf /Applications/Lidswitch.app
/usr/bin/pmset -a disablesleep 0
echo "uninstalled. SleepDisabled: $(ioreg -rd1 -c IOPMrootDomain | awk -F'= ' '/"SleepDisabled"/{print $2}')"
