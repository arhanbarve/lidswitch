#!/bin/bash
# Post-install checks that don't need the lid. Run as yourself (not sudo): ./verify.sh
# Covers: install layout, sudoers scope, T4 (crash → relaunch → orphan ON killed),
# T3 (manual pmset ON killed within the 5-min safety check), T17 (idle cost).
set -uo pipefail
LABEL=com.arhanbarve.lidswitch
PASS=0; FAIL=0
sudo -k  # drop any cached sudo password, or every sudo check below passes trivially
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
flag() { ioreg -rd1 -c IOPMrootDomain | awk -F'= ' '/"SleepDisabled"/{print $2}'; }
wait_flag() { # wait_flag VALUE SECONDS
    for ((i=0; i<$2; i++)); do [[ "$(flag)" == "$1" ]] && return 0; sleep 1; done; return 1; }

# Layout
[[ -f /etc/sudoers.d/lidswitch ]] && [[ "$(stat -f '%Su:%Sg %Lp' /etc/sudoers.d/lidswitch)" == "root:wheel 440" ]] \
    && ok "sudoers rule root:wheel 0440" || bad "sudoers rule missing or wrong perms"
[[ "$(stat -f '%Su' /Applications/Lidswitch.app/Contents/MacOS/Lidswitch 2>/dev/null)" == root ]] \
    && ok "app binary root-owned" || bad "app binary not root-owned"
launchctl print "system/$LABEL.bootoff" &>/dev/null && ok "boot daemon loaded" || bad "boot daemon not loaded"
launchctl print "gui/$(id -u)/$LABEL" &>/dev/null && ok "login agent loaded" || bad "login agent not loaded"
PID=$(pgrep -x Lidswitch) && ok "app running (pid $PID)" || bad "app not running"

# Sudoers scope: allowed exactly, nothing more
sudo -n -l /usr/bin/pmset -a disablesleep 0 &>/dev/null && sudo -n -l /usr/bin/pmset -a disablesleep 1 &>/dev/null \
    && ok "sudo allows the 2 commands" || bad "sudo rule does not allow the 2 commands"
# `sudo -l CMD` only says "allowed at all" (admins may run anything WITH a password),
# so check the passwordless entries themselves, and really try a harmless command.
NOPW=$(sudo -n -l 2>/dev/null | grep NOPASSWD)
[[ "$NOPW" == "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" ]] \
    && ok "only passwordless sudo entry is the 2 pmset commands" || bad "unexpected NOPASSWD entries: $NOPW"
sudo -n /usr/bin/pmset -g &>/dev/null && bad "sudo runs 'pmset -g' without password" || ok "sudo refuses 'pmset -g' without password"
sudo -n /usr/bin/true &>/dev/null && bad "sudo runs /usr/bin/true without password" || ok "sudo refuses other commands without password"

sleep 15  # let a just-launched app finish its launch check, so T3 exercises the safety timer
# T3: manual ON outside lidswitch must be killed (≤ 5 min safety check + 60s tolerance)
if [[ "$(flag)" != No ]]; then bad "T3 skipped: flag not OFF at start"
elif ! sudo -n /usr/bin/pmset -a disablesleep 1 &>/dev/null || [[ "$(flag)" != Yes ]]; then
    bad "T3 could not set flag ON (sudo rule?)"
else
    echo "....  T3 waiting up to 6 min for lidswitch to kill a manual ON"
    wait_flag No 360 && ok "T3 manual ON killed" || { bad "T3 manual ON NOT killed"; sudo -n /usr/bin/pmset -a disablesleep 0; }
fi

# T4: crash while ON → launchd relaunches → orphan ON killed at launch
if [[ -z "${PID:-}" ]]; then bad "T4 skipped: app not running"
elif ! sudo -n /usr/bin/pmset -a disablesleep 1 &>/dev/null || [[ "$(flag)" != Yes ]]; then
    bad "T4 could not set flag ON (sudo rule?)"
else
    kill -9 "$PID"
    echo "....  T4 waiting up to 30s for relaunch"
    wait_flag No 30 && ok "T4 relaunch killed orphan ON" || { bad "T4 orphan ON survived"; sudo -n /usr/bin/pmset -a disablesleep 0; }
    NEW=$(pgrep -x Lidswitch) && [[ "$NEW" != "$PID" ]] && ok "T4 relaunched (pid $NEW)" || bad "T4 not relaunched"
    PID=${NEW:-}
fi

# T17: idle cost
if [[ -n "${PID:-}" ]]; then
    CH=$(pgrep -P "$PID" | wc -l | tr -d ' ')
    [[ "$CH" == 0 ]] && ok "T17 no child processes" || bad "T17 $CH child processes"
    FP=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/{print $2}')
    [[ -n "$FP" && "${FP%.*}" -lt 30 ]] && ok "T17 footprint ${FP} MB" || bad "T17 footprint ${FP:-?} MB"
fi

[[ "$(flag)" == No ]] && ok "final state: normal lid sleep" || bad "final state: SleepDisabled still ON"
echo "---- $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
