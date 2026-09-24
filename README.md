# lidswitch

Menu bar toggle: keep the Mac awake with the lid closed, for a fixed time only, with
battery and heat cutoffs. Design and decisions: [SPEC.md](SPEC.md).

## Install / uninstall

```bash
./build.sh              # as you
sudo ./install.sh       # sudoers rule, boot reset daemon, login agent, /Applications/Lidswitch.app
sudo ./uninstall.sh     # removes all of it and restores lid sleep
```

Emergency manual reset, whatever state things are in: `sudo pmset -a disablesleep 0`

What install puts on the system:
| Path | Purpose |
|---|---|
| `/etc/sudoers.d/lidswitch` (root, 0440) | your user may run exactly `pmset -a disablesleep 0` / `1`, nothing else |
| `/Library/LaunchDaemons/com.arhanbarve.lidswitch.bootoff.plist` | runs `pmset -a disablesleep 0` at every boot |
| `~/Library/LaunchAgents/com.arhanbarve.lidswitch.plist` | starts app at login, relaunches it only on crash |
| `/Applications/Lidswitch.app` (root-owned) | the app |
| `~/Library/Logs/lidswitch.log` | every ON / OFF / refusal / failure |

App icon: `design/icon.svg`; after editing it run `design/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

## Use

Icon: 🌙 `moon.zzz` = normal sleep · ☕ `cup.and.saucer.fill` = staying awake · ⚠ = error (menu says what).
Menu → "Stay awake 30 min … 8 hours" (default 2h). While on: "+1 hour" (max 8h left), "Turn off now".
Quitting the app restores lid sleep.

## Rules (from SPEC §0)

Turns itself OFF (Mac then sleeps if lid closed) when any of these happen:
- timer runs out (5-min warning notification with "+1 hour")
- on battery and ≤ 20%
- thermal state **serious**/critical, or **fair** while lid closed on battery (bag)
- sleep was disabled by something other than lidswitch
- anything can't be read (flag, power source, battery %)

Refuses to turn ON under the same conditions.

## Tests

`swift test`: 25 policy tests (every rule, the boundaries, unknowns, and a check that nothing flaps from ON straight back to OFF).

`./verify.sh` after install (as you, not sudo): checks install layout, that sudo allows exactly the 2 commands and nothing else, T3, T4 and T17. Takes up to ~7 min.

Manual checklist after install (these need the real lid / root):
- [ ] T1 ON, close lid 60s, `pmset -g log | grep -iE 'Sleep  '` shows no new sleep
- [ ] T2 OFF, close lid, Mac sleeps
- [x] T3 (verify.sh, 2026-09-23) `sudo pmset -a disablesleep 1` by hand, close lid, lidswitch turns it OFF + notifies
- [x] T4 (verify.sh, 2026-09-23) ON, then `pkill -9 Lidswitch`, app relaunches in ~10s and turns it OFF
- [ ] T5 ON 30 min, lid closed, sleeps at expiry (warning at 25 min)
- [ ] T9 ON, reboot, `ioreg -rd1 -c IOPMrootDomain | grep SleepDisabled` = No
- [ ] T11 `sudo rm /etc/sudoers.d/lidswitch`, relaunch app, ⚠ icon, ON items hidden
- [ ] T13 ON, Apple menu → Sleep does nothing (expected side effect)
- [ ] T14 `sudo ./uninstall.sh`, all paths above gone
