# lidswitch

A macOS menu bar app that keeps your Mac awake with the lid closed, for a fixed time only, with
battery and heat cutoffs. Close the lid, keep a download, build or call going, and it turns itself
off before the Mac cooks in a bag.

Design and decisions: [SPEC.md](SPEC.md).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+, or its Command Line Tools: `xcode-select --install`)
- An admin account (the installer uses `sudo`)

## Install

```bash
git clone https://github.com/arhanbarve/lidswitch.git
cd lidswitch
./build.sh              # as yourself, not sudo
sudo ./install.sh       # run from your own account
```

The 🌙 icon appears in the menu bar and starts at every login. No developer certificate is needed:
without one the app is signed ad hoc, and the only cost is re-entering the hotspot password
(see [Hotspot](#hotspot-failover)) after each rebuild.

## Uninstall

```bash
sudo ./uninstall.sh     # removes everything below and restores normal lid sleep
```

Emergency manual reset, whatever state things are in: `sudo pmset -a disablesleep 0`

## What install changes on your system

lidswitch works by toggling `pmset disablesleep`, which needs root. The installer gives it exactly
that and nothing more:

| Path | Purpose |
|---|---|
| `/etc/sudoers.d/lidswitch` (root, 0440) | your user may run exactly `pmset -a disablesleep 0` / `1`, nothing else |
| `/Library/LaunchDaemons/com.arhanbarve.lidswitch.bootoff.plist` | runs `pmset -a disablesleep 0` at every boot |
| `~/Library/LaunchAgents/com.arhanbarve.lidswitch.plist` | starts the app at login, relaunches it only on crash |
| `/Applications/Lidswitch.app` (root-owned) | the app |
| `~/Library/Logs/lidswitch.log` | every ON / OFF / refusal / failure |
| Keychain item `com.arhanbarve.lidswitch.hotspot` (only if you set a hotspot) | the hotspot password; "Forget hotspot" deletes it |

Everything is a short script you can read before running: [`install.sh`](install.sh) has a
`--dry-run DIR` mode that writes and validates the generated files without touching the system.

**A closed, awake laptop in a bag gets hot.** The cutoffs below are there for that; don't defeat them.

## Use

Icon: 🌙 `moon.zzz` = normal sleep · ☕ `cup.and.saucer.fill` = staying awake · ⚠ = error (menu says what).
Menu → "Stay awake 30 min … 8 hours" (default 2h). While on: "+1 hour" (max 8h left), "Turn off now".
Quitting the app restores lid sleep.

Only one copy runs. Opening the app again (Finder, Spotlight) shows its menu, at the mouse if
macOS is hiding the icon (System Settings → Menu Bar).

### Rules

Turns itself OFF (the Mac then sleeps if the lid is closed) when any of these happen:
- timer runs out (5-min warning notification with "+1 hour")
- on battery and ≤ 20% (≤ 5% if you started it with "anyway (low battery)", which the menu offers when the battery is already at or below 20%)
- thermal state **serious**/critical, or **fair** while lid closed on battery (bag)
- sleep was disabled by something other than lidswitch
- anything can't be read (flag, power source, battery %)

Refuses to turn ON under the same conditions.

### Speakers

While on with the lid closed, the built-in speakers are muted and stay muted (anything that unmutes
them is undone at once). Opening the lid puts back whatever they were before. AirPods, headphones
and external displays are not touched.

### Hotspot failover

Menu → "Set hotspot for when Wi-Fi drops…", enter your iPhone hotspot's name and password
once, and allow Location Services when asked (macOS needs it to show Wi-Fi names; your location is
never read). On the iPhone: Settings → Personal Hotspot → Allow Others to Join. Then, while on with
the lid closed, if the Mac has no network for 10 seconds it joins the hotspot, retrying for up to
5 minutes. It never switches back by itself: opening the lid tells you it is on the hotspot.

### Caffeinate

Icon `mug` (outline) = a `caffeinate` is running (anyone's, lid override off). The menu lists each one in plain words (e.g. "screen on, no idle sleep · 58m left"; hover for the raw flags) with
"Stop", and "Caffeinate ▸ 1–8 hours" starts `caffeinate -dim -t N` (no `-s`, so it can't block
the sleep lidswitch requests when an override ends with the lid shut). Caffeinate only stops
idle sleep; closing the lid still sleeps the Mac.

## Development

```bash
swift test          # 35 policy tests: every rule, the boundaries, unknowns, no ON→OFF flapping
./update.sh         # rebuild + reinstall (asks for your password in a macOS dialog)
./verify.sh         # after install, as yourself, not sudo: install layout, sudoers scope, crash recovery, idle cost (~7 min)
```

The tests that need a real lid or root (T1, T2, T5, T9, …) are a manual checklist in
[SPEC.md](SPEC.md).

`build.sh` signs with an "Apple Development" certificate if you have one, so the Keychain item and
Location Services grant survive rebuilds. Override with `LIDSWITCH_SIGN="<identity>"`.

App icon: `design/icon.svg`; after editing it run `design/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

## License

[MIT](LICENSE)
