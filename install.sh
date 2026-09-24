#!/bin/bash
# Install lidswitch. Run: ./build.sh && sudo ./install.sh
# Dry run (no root, writes generated files to DIR and validates them): ./install.sh --dry-run DIR
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.arhanbarve.lidswitch
BOOT_LABEL=$LABEL.bootoff
APP_SRC=build/Lidswitch.app
APP_DST=/Applications/Lidswitch.app
SUDOERS=/etc/sudoers.d/lidswitch
DAEMON=/Library/LaunchDaemons/$BOOT_LABEL.plist

DRY=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY="${2:?usage: --dry-run DIR}"; mkdir -p "$DRY"
    TARGET_USER=$(id -un)
else
    [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || { echo "run via sudo from your own account" >&2; exit 1; }
    [[ -d "$APP_SRC" ]] || { echo "missing $APP_SRC, run ./build.sh first" >&2; exit 1; }
fi
# Username goes into sudoers: allow only plain names.
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || { echo "unexpected username: $TARGET_USER" >&2; exit 1; }
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')
AGENT=$TARGET_HOME/Library/LaunchAgents/$LABEL.plist

WORK=${DRY:-$(mktemp -d)}

# 1. sudoers: exactly two commands, exact arguments, this user only.
cat > "$WORK/sudoers" <<EOF
# lidswitch: allow toggling lid-close sleep without a password. Nothing else.
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
visudo -cf "$WORK/sudoers" >/dev/null

# 2. Boot daemon: force lid sleep back ON at every boot, before anyone logs in.
cat > "$WORK/daemon.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BOOT_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/pmset</string><string>-a</string><string>disablesleep</string><string>0</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
plutil -lint "$WORK/daemon.plist" >/dev/null

# 3. Login agent: start the menu bar app; relaunch only if it crashes (quit = exit 0 = stays quit).
cat > "$WORK/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP_DST/Contents/MacOS/Lidswitch</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
plutil -lint "$WORK/agent.plist" >/dev/null

if [[ -n "$DRY" ]]; then
    echo "dry run OK: generated + validated files in $DRY"
    exit 0
fi

grep -qE '^#includedir /private/etc/sudoers.d' /etc/sudoers || { echo "/etc/sudoers lacks #includedir sudoers.d" >&2; exit 1; }

# Stop any running copy first (its quit handler restores lid sleep).
launchctl bootout "gui/$TARGET_UID/$LABEL" 2>/dev/null || true
launchctl bootout "system/$BOOT_LABEL" 2>/dev/null || true
for _ in {1..20}; do  # bootout is async; bootstrap fails if the old job is still there
    launchctl print "gui/$TARGET_UID/$LABEL" &>/dev/null || launchctl print "system/$BOOT_LABEL" &>/dev/null || break
    sleep 0.5
done

# App is root-owned so your user account can't modify the binary.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
chown -R root:wheel "$APP_DST"
chmod -R go-w "$APP_DST"

install -m 0440 -o root -g wheel "$WORK/sudoers" "$SUDOERS"
visudo -c >/dev/null || { rm -f "$SUDOERS"; echo "sudoers check failed, rule removed" >&2; exit 1; }

install -m 0644 -o root -g wheel "$WORK/daemon.plist" "$DAEMON"
launchctl bootstrap system "$DAEMON"

mkdir -p "$(dirname "$AGENT")"
install -m 0644 -o "$TARGET_USER" -g staff "$WORK/agent.plist" "$AGENT"
/usr/bin/pmset -a disablesleep 0
launchctl bootstrap "gui/$TARGET_UID" "$AGENT"

rm -rf "$WORK"
echo "installed. Menu bar icon: moon = normal sleep, cup = staying awake."
