# lidswitch — spec

Status: built 2026-09-23, "very restrictive" mode: every unknown → OFF, app binary root-owned. See README for install + manual checks.

## 0. Decisions (grilling 2026-09-23)

| # | Question | Decision |
|---|---|---|
| Q0 | Use case | Both: long jobs with lid shut on desk **and** carrying it in a bag while jobs run |
| Q1 | Auto-kill triggers | Battery ≤ 20% (on battery), any thermal/perf warning, timer expiry. Unplugging is NOT a trigger |
| Q2 | Timer | Default 2h. Choices 30m/1h/2h/4h/8h. **No "forever"** |
| Q3 | Privilege | `/etc/sudoers.d/lidswitch` NOPASSWD for exactly `pmset -a disablesleep 0` and `… 1`, validated with `visudo -cf` |
| Q4 | UI | Native Swift menu bar app |
| Q5 | Alerts on cutoff | macOS notification + line in `~/Library/Logs/lidswitch.log` |
| Q6 | Flag ON but not started by lidswitch (manual pmset, stale from before) | **Turn OFF immediately** + notify. Only lidswitch may hold it ON |
| Q7 | Quit / crash | Quit = OFF first. Crash → launchd KeepAlive relaunches app → Q6 rule kills the orphaned ON. Boot LaunchDaemon forces OFF every restart. No separate watchdog |
| Q8 | Heat cutoff (`ProcessInfo.thermalState`) | Lid closed **and** on battery (likely bag) → OFF at **fair**. Otherwise (AC / lid open) → OFF at **serious**. Critical → always OFF. Replaces Q1's "any thermal warning" |

Derived defaults (not asked, change if wrong):
- Refuse to turn ON if on battery and already ≤ 20%.
- **No polling loop.** Event-driven only, see §3a (CPU budget, added after Arhan flagged CPU cost).
- Notification 5 min before timer expiry, with "+1h" action.
- Consequence of Q6+Q7: a crash while in a bag ends the override → Mac sleeps. Accepted: that's the safe side.
- Consequence of Q6: manual `sudo pmset -a disablesleep 1` stops working while the app runs.

## 1. Goal

One-click toggle (no terminal) for "stay awake when lid closes" on this MacBook,
with guardrails so it can never be left on by accident and cook the laptop in a bag.

Non-goals (for now): scheduling, per-app rules, general sleep management
(idle sleep is already covered by `caffeinate`), multi-machine support.

## 2. How macOS lid sleep actually works (verified on this machine)

Machine: Mac17,8 / M5 Pro, macOS 27.0 (26A428).

| Fact | Evidence |
|---|---|
| Lid close forces sleep regardless of `caffeinate` / idle assertions | `AppleClamshellCausesSleep = Yes` while 10+ caffeinate assertions active |
| Built-in clamshell mode only works with AC + external display (+ input device) | Apple behaviour; no external display attached now |
| The only lid override is the kernel flag `SleepDisabled` | set by `pmset -a disablesleep 1` |
| Setting the flag needs root | `sudo -n true` → "a password is required" |
| **Reading** the flag does not need root | `ioreg -rd1 -c IOPMrootDomain` → `"SleepDisabled" = No` |
| Lid position readable without root | `AppleClamshellState` (Yes = closed) |
| Battery / power source readable without root | `pmset -g ps` |
| Thermal warnings readable without root | `pmset -g therm` |
| Clearing the flag while the lid is **already closed** does NOT sleep the Mac; app must request sleep (`IOPMSleepSystem`, no root) | 2026-09-24: flag cleared 12:02:18 lid closed, still awake 12:03:05; `IOPMSleepSystem` as user → "Software Sleep" 12:03:54 |

Side effects of `SleepDisabled = 1` (important):
- Blocks **all** sleep: lid, Apple-menu Sleep, idle sleep. Screen still turns off.
- Stored in power-management prefs → **survives reboot** (to verify in test T9).
- Nothing in macOS turns it back off. Forgotten flag = laptop never sleeps, in a bag, on battery.

## 3. Architecture (proposed)

```
 ┌───────────────┐   read-only (IOKit in-proc)    ┌─────────────┐
 │  Menu bar UI  │ ─────────────────────────────▶ │   kernel    │
 │ (user, no pw) │                                │ SleepDisabled│
 └──────┬────────┘                                └──────▲──────┘
        │ "on" / "off"                                   │ pmset -a disablesleep 0|1
        ▼                                                │
 ┌─────────────────────────────────────────────┐         │
 │ privileged path: exactly 2 allowed commands  │ ───────┘
 │  (sudoers NOPASSWD rule, Q3)                 │
 └─────────────────────────────────────────────┘
        ▲
 ┌──────┴──────────────────────────────────────┐
 │ same app enforces: timer, battery, thermal,  │  events only (§3a)
 │ orphan-ON kill. launchd KeepAlive + boot OFF │
 └─────────────────────────────────────────────┘
```

Core rules:
1. **Kernel is source of truth.** UI never trusts its own memory; re-reads flag on every event (§3a) and after every write.
2. **Fail safe = OFF.** Any error, crash, reboot, unknown state → force `disablesleep 0`.
3. **Least privilege.** The privileged surface allows exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1`. Nothing else, no args.
4. **Crash safety via launchd, not a watchdog** (Q7). App = only enforcer; KeepAlive relaunches it; boot daemon forces OFF.
5. **Near-zero CPU.** No subprocesses in steady state, no polling (§3a).

## 3a. CPU / energy budget

Hard targets, measured with `top -pid`, `ps -o %cpu,rss`, and Activity Monitor's Energy tab:

| Metric | Budget |
|---|---|
| Idle CPU (override OFF or ON, menu closed) | ~0.0% (< 0.1% averaged over 10 min) |
| Timer wakeups while idle | ≤ 1 per 5 min |
| Memory (`footprint` phys_footprint; RSS over-counts shared frameworks) | < 30 MB |
| Subprocesses spawned while idle | 0 (only `sudo pmset` on an actual toggle) |
| CPU per toggle | one short `sudo pmset` exec, < 50 ms |

How that's achieved: every signal comes from an OS event, read in-process:
| Signal | Source (no shelling out) |
|---|---|
| Battery % / AC change | `IOPSNotificationCreateRunLoopSource` (fires only on power-source change) |
| Thermal | `ProcessInfo.thermalStateDidChangeNotification` (fires on state change) |
| Lid close/open | IOKit interest notification on `IOPMrootDomain` (`kIOPMMessageClamshellStateChange`) |
| SleepDisabled flag | read with `IORegistryEntryCreateCFProperty` on: launch, lid close, wake, menu open, after each write, + 1 safety check every 5 min (timer leeway 60s so macOS can coalesce) |
| Auto-off timer | one one-shot timer at the deadline (not ticking every second) |
| Countdown text | computed only while the menu is open |

Why the flag has a 5-min fallback check: macOS may not send an event when someone runs `pmset disablesleep` manually.
Worst case, an ON set by someone else (Q6) lives ≤ 5 min, but it's always caught **at lid close**, the moment that matters.

## 4. Options per layer

### 4a. Privilege (chose A, Q3)
| Option | Pros | Cons |
|---|---|---|
| A. `/etc/sudoers.d/lidswitch` NOPASSWD for the 2 exact commands (recommended) | ~3 lines, auditable, `visudo -c` validates, trivially removable | any process as your user can flip the flag (low harm: only these 2 cmds) |
| B. Root LaunchDaemon helper + XPC (SMAppService) | "proper" Mac app pattern | lots of code, code-signing, notarization friction |
| C. Admin password prompt each toggle (`osascript … with administrator privileges`) | zero persistent privilege | password every time; defeats the point |
| D. Enable Touch ID for sudo (`sudo_local`) + prompt | no stored grant | still a prompt each toggle |

### 4b. UI (chose native, Q4)
| Option | Notes |
|---|---|
| Native Swift menu bar app (recommended; Xcode present) | icon shows real state, timer countdown, no deps |
| SwiftBar plugin (bash) | fastest to build, needs SwiftBar installed |
| Shortcuts / Raycast / hotkey | no persistent state indicator |

### 4c. Safety policy
Resolved — see §0 Q1, Q2, Q5–Q7.

## 5. Edge-case matrix (test plan)

| # | Scenario | Expected | How to test |
|---|---|---|---|
| T1 | Toggle ON, close lid | stays awake (network, audio keep running) | close lid 60s, `pmset -g log \| grep -i sleep` shows none; ping loop continues |
| T2 | Toggle OFF, close lid | sleeps normally | `pmset -g log` shows Clamshell Sleep |
| T3 | Flag flipped ON outside app (manual `pmset`) | turned OFF + notified within 5 min, or immediately on lid close (Q6) | run pmset manually, close lid |
| T4 | App quit while ON / `kill -9` while ON | quit → OFF first; kill → relaunched → orphan ON killed | quit, `kill -9`, check ioreg |
| T5 | Timer expires with lid closed | OFF → Mac sleeps immediately | 1-min timer, close lid |
| T6 | Battery crosses cutoff | OFF + notification | simulate by setting cutoff above current % |
| T7 | AC unplugged while ON | stays ON, battery cutoff armed | unplug |
| T8 | Thermal cutoffs per Q8 | bag (lid closed+battery): OFF at fair; AC: OFF at serious; critical always OFF | policy unit tests with fake thermal states (can't safely cause a real one) |
| T9 | Reboot while ON | comes back OFF | reboot, read ioreg before login |
| T10 | sudoers file malformed | install refuses | `visudo -cf` gate in installer; test with broken file in scratch |
| T11 | pmset fails / sudo rule removed | UI shows error, state re-read, never shows ON falsely | delete rule, click toggle |
| T12 | Two toggles race (double-click) | final state = last intent, idempotent | rapid clicks |
| T13 | Sleep via Apple menu while ON | blocked (known side effect) → UI should say so | try it |
| T14 | Uninstall | removes sudoers rule, launchd jobs, sets OFF | run uninstall, grep for leftovers |
| T15 | macOS update resets pmset/sudoers | detect + prompt reinstall | check after update |
| T16 | External display + AC (native clamshell) | app irrelevant; should not interfere | plug display |
| T19 | Lid closed + on battery at 'fair', then plug in AC | re-evaluated with AC rule (serious); already-OFF stays OFF | policy unit test |
| T17 | CPU idle budget | < 0.1% avg over 10 min, 0 child processes, RSS < 30 MB, in both states | `top -l 60 -s 10 -pid <pid>`; `pgrep -P <pid>` |
| T18 | Wakeups budget | ≤ 1 timer wakeup / 5 min idle | `sudo powermetrics --samplers tasks -i 60000 -n 10`, filter pid |

Unit-testable without root: state parsing (ioreg/pmset output fixtures), policy engine
(battery %, AC, thermal, timer → desired state). Root-requiring tests (T1, T2, T5, T9)
are manual checklists run once by Arhan.

## 6. Build order (after grilling)
1. Policy engine (pure Swift, inputs → desired state) + unit tests for every §0 rule.
2. Installer/uninstaller (sudoers via `visudo -cf`, launchd plists). Dry-run mode.
3. launchd plists: KeepAlive agent for app, boot daemon forcing OFF.
4. Menu bar UI.
5. Manual root test pass T1–T16.

## 7. Rollback
Any time: `sudo pmset -a disablesleep 0` and `sudo rm /etc/sudoers.d/lidswitch`.
