# LidKeeper

A small, experimental macOS menu bar app for keeping a MacBook awake with its lid closed, including on battery, while leaving explicit system sleep available.

**Status: developer preview.** Uses a private kernel interface. A successful build or API call does not prove closed-lid behavior on every Mac. Physical lid, battery, and power-button validation is still required. macOS 13+; Swift 5.9+; no dependencies.

## Run

Install Apple's Xcode Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/BlueRaddish/LidKeeper.git
cd LidKeeper
bash scripts/build.sh
open dist/LidKeeper.app
```

Click the laptop icon in the menu bar and choose a 30-minute, 1-hour, or 2-hour session. The app starts inactive. No login item, privileged helper, or permanent power preference is installed. The local build is ad-hoc signed, not notarized.

Timed options remain visible during a session: a checkmark identifies the active duration, and a dash indicates startup. Click the checked duration or **End Session** to stop. Trigger selections have checkmarks; matching activities also show **Running**. The battery/heat row opens a submenu with checked, clickable explanations of both protections. These cutoffs remain fixed in this version.

### Trigger-based sessions

Open **Trigger-Based**, check the activities you want to watch, then choose **Watch Selected Triggers**. Multiple selections mean **any selected activity** can keep your Mac awake:

- **Terminal Sessions**: a shell attached to a terminal under your user account. Includes idle prompts and shells in Terminal, iTerm, editor terminals, SSH, and tmux. An app with no shell session does not count. Supported shells: sh, bash, zsh, fish, nu, xonsh, tcsh, csh.
- **Codex CLI / Claude Code**: an executable named `codex` or `claude` attached to a terminal. This detects a running CLI, not whether the agent is currently generating a response. Wrappers reported only as `node` or another executable are not recognized.
- **Codex App / Claude Desktop / Visual Studio Code / Cursor**: the desktop app is running, even if it has no open windows. Quit it to stop matching.

The worker checks about every two seconds. It acquires keep-awake controls when any selection matches, releases them when none match, and continues watching. Waiting does not hold a power assertion. The menu shows the matching activities, or “Watching · no selected triggers running.” Watching has no fixed time limit and cannot wake an already sleeping Mac.

The main menu explicitly shows **Trigger-Based: On · Keeping Awake**, **On · Waiting**, or **Off**, with a checkmark while enabled. Without opening the menu, **Auto · Awake** or **Auto · Waiting** in the menu bar tells you trigger mode is on. Waiting means automation is enabled but is not currently preventing sleep.

**Stop Watching**, **End Session**, manual system sleep, quitting, a monitoring error, or a battery/thermal cutoff disarms watching completely. Re-enable it explicitly afterward. To change selections, stop watching first. Selections are remembered, but watching never starts automatically on launch. Timed sessions and watching are mutually exclusive.

Monitoring reads only your account's executable names and terminal assignments, plus running app bundle identifiers. It does not read terminal contents, command arguments, prompts, or project files. No Accessibility or Automation permission is needed. A sandbox or system policy that blocks process inspection will stop watching with an error.

Sessions end at the time limit, at or below 20% while on battery, on serious/critical thermal pressure, when battery readings are unavailable on battery, or when the app exits. Checks run every two seconds. Keep the closed Mac ventilated; don't put an active Mac in a bag.

**Sleep Now** ends the session and requests system sleep. An explicit system sleep notification also ends the session, so it will not automatically reactivate after waking. Touch ID buttons can lock the screen instead of requesting system sleep; LidKeeper does not remap the physical button.

If you previously ran `sudo pmset -a disablesleep 1`, undo it before starting:

```sh
sudo pmset -a disablesleep 0
```

LidKeeper refuses to start while global sleep is disabled. It does not change that preference on your behalf.

## How it works

The UI launches a separate worker process. That worker opens the power-management user client, calls the private `kPMSetClamshellSleepState` selector (12), and holds a public `PreventUserIdleSystemSleep` assertion. The lid selector changes only the clamshell sleep mask; the idle assertion lets jobs keep running without blocking explicit sleep. Neither sets `SleepDisabled`.

The worker owns cleanup. The UI keeps a pipe open as a lifetime lease; EOF, termination signals, the session deadline, or a missing parent ends the session and releases both controls. This covers the UI crashing, but **killing the worker with SIGKILL cannot run cleanup**. Restarting the Mac clears the kernel lid flag. Quitting the app normally waits for cleanup.

### Important limitations

- The private selector shares the `powerd` clamshell bit, not a per-process resource. macOS or another utility can overwrite it, and releasing it can interfere with another owner's lid suppression. Avoid running other lid-control utilities at the same time. This preview does not try to repeatedly overwrite macOS's decisions.
- There is no reliable public readback for ownership of that bit. “Session active” means the API accepted the request, not that physical lid sleep was verified.
- macOS can change or restrict the private interface. An error is surfaced; there is no fallback to global sleep suppression.
- Physical power-button behavior varies by Mac. Explicit sleep is preserved by design; no keyboard interception, Accessibility permission, or Touch ID remapping is used. Hardware testing must confirm the experience you want.
- Thermal monitoring is an OS pressure signal, not a temperature sensor or a guarantee against overheating. Battery cutoff restores normal sleep eligibility; other apps can still prevent idle sleep.
- No auto-launch, persisted sessions, telemetry, updates, or App Store support in this preview.

Apple source references:

- [Selector definitions](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/pwr_mgt/IOPMLibDefs.h)
- [RootDomainUserClient dispatch](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp)
- [Kernel clamshell mask handling](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp)
- [powerd's clamshell state evaluation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c)

## Development and validation

The 0.2.3 maintenance pass checks thermal pressure before activation, reports monitoring failures with a nonzero exit status, and drains worker messages before processing worker exit. Complete lines are decoded together so split UTF-8 characters survive pipe reads. Power-control cleanup errors remain visible and prevent reacquisition. Terminal-only watching skips desktop-app enumeration; polling allows 100 ms of timer coalescing.

```sh
swift run PolicyChecks
bash scripts/build.sh
.build/release/LidKeeper --diagnose
.build/release/LidKeeper --diagnose-triggers
```

Policy checks exercise battery, time, thermal, and parent-liveness decisions without requiring XCTest or a full Xcode installation. CI builds the app on macOS. Neither substitutes for testing sleep transitions on a physical MacBook.

For an opt-in API smoke test on a physical Mac, keep the lid open and run `python3 scripts/smoke.py`. It briefly enables the lid control and checks stop, UI disconnect, timeout, signal cleanup, and rejection of concurrent sessions; it never requests system sleep.

Initial local validation: release build and nine policy checks passed on an Intel MacBookPro16,1 running macOS 26.7. On battery, the private API accepted start/stop requests without elevated privileges and all five smoke checks passed. Global `SleepDisabled` remained false. Physical lid closure and power-button transitions have not yet been validated.

Manual test checklist (save ongoing work first):

1. On battery, start a session, close the lid, and confirm a running job continues. Reopen the lid.
2. Use Apple menu → Sleep during a session. Confirm sleep occurs and the session is inactive after wake.
3. Test the physical power button separately, distinguishing screen locking from system sleep.
4. End a session; confirm ordinary lid sleep returns.
5. Repeat on charger and with/without an external display.
6. Force-quit only the UI; confirm the worker exits and normal lid sleep returns.
7. Inspect `pmset -g` to confirm `SleepDisabled` was not enabled.
8. Arm Terminal Sessions: open a shell and check the active status; close all terminal shells and check that the status returns to waiting. Repeat with Codex CLI and Claude Code individually.
9. Select two triggers and verify either one keeps the session active; close both and verify waiting. Verify manual sleep and safety cutoffs disarm watching rather than restarting it.

Report Mac model, macOS version, charger/display setup, and which check failed. Do not include serial numbers or private logs.

## License

MIT. Private interfaces are referenced from Apple source; this project does not bundle Apple implementation code.
