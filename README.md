# LidKeeper

A macOS menu-bar app that keeps a MacBook awake with its lid closed, including on battery, for a timed session or while selected developer activity is running. macOS 13+; Swift 5.9+; no package dependencies.

**Version 0.3 is awaiting physical lid-closure validation.** The previous private clamshell selector accepted calls on this Mac but did not reliably prevent closed-lid sleep. LidKeeper now uses macOS's global `pmset -a disablesleep 1` override, the mechanism used by comparable open-source utilities. It confirms `SleepDisabled` before reporting a session active.

## Install and use

```sh
git clone https://github.com/BlueRaddish/LidKeeper.git
cd LidKeeper
bash scripts/build.sh
open dist/LidKeeper.app
```

Choose a 30-minute, 1-hour, or 2-hour session, or open **Trigger-Based**, select activities, and choose **Watch Selected Triggers**. The app starts inactive. It asks for administrator authentication once to install a narrow sudoers rule allowing only `pmset -a disablesleep 0` and `pmset -a disablesleep 1`. It also installs a per-user LaunchAgent to restore normal sleep after a crashed worker. No administrator password is stored by LidKeeper. The local build is ad-hoc signed, not notarized.

The menu shows a checkmark beside the active duration and beside Trigger-Based while watching. The menu bar reads **Auto · Awake** or **Auto · Waiting** in trigger mode. **Waiting** means no selected activity is running and the sleep override is off. Trigger watching does not wake an already sleeping Mac and does not start automatically at login.

Trigger choices match if **any** selected activity runs:

- **Terminal Sessions:** a shell attached to a terminal under your user account. Idle prompts, editor terminals, SSH, and tmux count. The terminal app alone does not.
- **Codex CLI / Claude Code:** an executable named `codex` or `claude` attached to a terminal. This detects a running CLI, not whether it is currently generating a response.
- **Codex App / Claude Desktop / VS Code / Cursor:** a running desktop app, even with no open windows.

Monitoring checks about every two seconds. It reads executable names, terminal assignments, and app bundle identifiers; it does not read command arguments or terminal contents. To change trigger selections, stop watching first. Timed and trigger-based sessions are mutually exclusive. Monitoring errors, an app exit, manual sleep, or a safety cutoff disarm watching.

Sessions end at the deadline, at or below 20% battery while unplugged, on serious/critical thermal pressure, on missing battery data while unplugged, or when the app exits. The safety row in the menu opens clickable explanations. Keep the closed Mac ventilated; do not put an active Mac in a bag.

## Sleep behavior and limitations

The override blocks ordinary system sleep, including lid-close and idle sleep, while active. **It can also block Apple-menu and physical power-button sleep.** LidKeeper does not intercept or remap the button. Use **Sleep Now** in LidKeeper: it restores normal sleep first, then requests sleep. A Touch ID button may lock the screen without requesting system sleep. Check the screen-lock behavior you want before leaving an active Mac unattended.

The worker holds a public `PreventUserIdleSystemSleep` assertion and turns on `SleepDisabled` only while a timed session or selected trigger is active. It turns the override off before releasing its lease. A separate LaunchAgent checks the lease every 20 seconds and attempts to restore normal sleep after 60 seconds without a heartbeat. The app refuses to take over if another utility already has `SleepDisabled` on. A force quit, OS failure, or broken privilege rule can delay restoration. To restore normal sleep manually:

```sh
sudo pmset -a disablesleep 0
```

The override cannot guarantee survival of shutdown, power loss, or emergency battery/thermal protection. It does not change standby or hibernation settings; those occur after the Mac has entered sleep. It affects all power sources during an active session so that closing the lid on battery is covered. Removing LidKeeper requires removing its LaunchAgent and `/etc/sudoers.d/lidkeeper-disablesleep` administrator rule as well as the app. The rule grants no general administrator access, but any process running as your account can invoke those exact two `pmset` commands; that is the cost of unattended trigger activation and cleanup.

## Why the implementation changed

Apple's clamshell flag is a shared power-management state. The old private selector could set that bit, but `powerd` could change it back. This Mac's `pmset` history showed several **Clamshell Sleep** transitions on battery. Those logs alone do not prove LidKeeper was active at each transition, but the user-observed failure matches the implementation weakness. A successful API call was never proof of actual closed-lid behavior.

Comparable projects use the global override or a privileged helper for it: [SleepSwitch](https://github.com/AppsGanin/SleepSwitch), [Sleepless](https://github.com/Aboudjem/Sleepless), [Lidless](https://github.com/junaidxabd/lidless), and [Amped](https://github.com/gustaferiksson/amped). [Close Your Laptop](https://github.com/jgassens/Close-your-laptop) combines assertions with the override. See [Apple's clamshell property definitions](https://github.com/apple/darwin-xnu/blob/main/iokit/IOKit/pwr_mgt/IOPM.h) and [powerd's clamshell handling](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c).

## Development and validation

```sh
swift run PolicyChecks
bash scripts/build.sh
dist/LidKeeper.app/Contents/MacOS/LidKeeper --diagnose
dist/LidKeeper.app/Contents/MacOS/LidKeeper --diagnose-triggers
```

The policy checks cover time, battery, thermal pressure, process matching, and worker message parsing. They do not require privileges. The build and diagnosis are safe with no session active. The former opt-in smoke test needs an installed administrator rule before it can exercise the new mechanism; never run it with the lid closed.

Physical validation remains required on the target Mac: while unplugged, start a session and confirm `--diagnose` reports `Global sleep disabled: Optional(true)`; close the lid and confirm a running job continues; reopen it, end the session, and confirm `Optional(false)`. Repeat with each desired trigger and on charger. Verify battery/thermal cutoffs and crash recovery separately. Power-button behavior must be tested separately because hardware and Touch ID semantics vary.

For a repeatable lid test, start a LidKeeper session and then run `python3 scripts/lid_probe.py --seconds 90` from the repository. Close the lid for at least 30 seconds and reopen it. The probe records one-second heartbeats, the actual clamshell sensor state and `SleepDisabled`, then checks macOS's sleep log. It reports a pass only if it observed at least 25 closed-lid samples without a heartbeat gap, sleep event or lost override. It writes a CSV under `~/Library/Logs/LidKeeper/` and does not change power settings. `--baseline --seconds 3` checks the probe with LidKeeper inactive.

A VM can exercise software paths, but it cannot establish that a real MacBook stays awake when its physical lid closes. Apple's macOS guest path in [Virtualization](https://developer.apple.com/documentation/virtualization/virtualize-macos-on-a-mac) is for Apple silicon; virtual hardware may also lack the battery and lid sensors this app requires. Use the physical probe for the remaining release gate.

## License

MIT.
