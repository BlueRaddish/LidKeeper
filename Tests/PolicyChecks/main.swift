import Foundation
import SessionPolicy

let now = Date(timeIntervalSince1970: 1_000)
func reason(battery: Int? = 80, onBattery: Bool = true, hot: Bool = false,
            alive: Bool = true, seconds: Double = 60) -> String? {
    SessionPolicy(deadline: now.addingTimeInterval(seconds)).stopReason(
        now: now, batteryPercent: battery, onBattery: onBattery,
        thermalCritical: hot, ownerAlive: alive)
}
let terminalRows = TerminalProcess.parse("""
  ttys001 /bin/zsh
  ?? /bin/bash
  ttys002 /Users/dev/.local/bin/claude
  ttys003 /opt/homebrew/bin/codex
  ?? /Applications/Codex.app/Contents/MacOS/codex
  ?? /Applications/Visual Studio Code.app/Contents/MacOS/Electron
""")
let detached = TerminalProcess.parse("?? /bin/zsh\n?? /usr/local/bin/codex\n?? /usr/local/bin/claude")
var cases: [(String, Bool)] = [
    ("Healthy session continues", reason() == nil),
    ("Stops at battery floor", reason(battery: 20) != nil),
    ("Stops below battery floor", reason(battery: 19) != nil),
    ("Continues above battery floor", reason(battery: 21) == nil),
    ("Low battery on charger continues", reason(battery: 5, onBattery: false) == nil),
    ("Unknown battery fails closed", reason(battery: nil) != nil),
    ("Deadline ends session", reason(seconds: 0) != nil),
    ("App disconnect ends session", reason(alive: false) != nil),
    ("High heat stops even on charger", reason(onBattery: false, hot: true) != nil),
    ("Terminal shell detected", ActivityTrigger.terminal.matches(processes: terminalRows, bundles: [])),
    ("Codex CLI detected", ActivityTrigger.codexCLI.matches(processes: terminalRows, bundles: [])),
    ("Claude CLI detected", ActivityTrigger.claudeCLI.matches(processes: terminalRows, bundles: [])),
    ("Background processes do not count as terminal sessions", !ActivityTrigger.terminal.matches(processes: detached, bundles: [])),
    ("Codex app helper does not count as CLI", !ActivityTrigger.codexCLI.matches(processes: detached, bundles: [])),
    ("Detached Claude does not count as CLI", !ActivityTrigger.claudeCLI.matches(processes: detached, bundles: [])),
    ("Login shell detected", ActivityTrigger.terminal.matches(processes: TerminalProcess.parse("ttys001 -zsh"), bundles: [])),
    ("No sessions means no trigger", !ActivityTrigger.terminal.matches(processes: [], bundles: [])),
    ("Similar executable name does not match", !ActivityTrigger.codexCLI.matches(processes: [TerminalProcess(name: "codex-helper", hasTerminal: true)], bundles: [])),
    ("Desktop app detected independently of TTY", ActivityTrigger.codexApp.matches(processes: [], bundles: ["com.openai.codex"])),
    ("Desktop helper bundle does not match", !ActivityTrigger.codexApp.matches(processes: [], bundles: ["com.openai.codex.helper"])),
    ("Claude desktop detected", ActivityTrigger.claudeApp.matches(processes: [], bundles: ["com.anthropic.claudefordesktop"])),
    ("VS Code detected", ActivityTrigger.vscode.matches(processes: [], bundles: ["com.microsoft.VSCode"])),
    ("Cursor detected", ActivityTrigger.cursor.matches(processes: [], bundles: ["com.todesktop.230313mzl4w4u92"])),
    ("Malformed rows ignored", TerminalProcess.parse("\ninvalid\n").isEmpty)
]
cases.append(("Revoked terminal does not count", !ActivityTrigger.terminal.matches(processes: TerminalProcess.parse("ttys001- /bin/zsh"), bundles: [])))
var session = TriggerSession()
var starts = 0, stops = 0
func update(_ matches: [ActivityTrigger]) {
    try! session.update(matches: matches, activate: { starts += 1 }, deactivate: { stops += 1 })
}
update([])
cases.append(("Waiting does not acquire controls", starts == 0 && stops == 0 && !session.active))
update([.terminal])
cases.append(("First match activates", starts == 1 && session.active))
update([.terminal, .codexCLI])
update([.codexCLI])
cases.append(("Any remaining match retains controls without reacquiring", starts == 1 && stops == 0 && session.active))
update([])
update([])
cases.append(("Last match exiting releases exactly once", stops == 1 && !session.active))
update([.claudeCLI])
cases.append(("New activity reactivates watching", starts == 2 && session.active))
enum TestError: Error { case denied }
do {
    try session.update(matches: [], activate: {}, deactivate: { throw TestError.denied })
    cases.append(("Release failure propagates", false))
} catch { cases.append(("Release failure preserves cleanup responsibility", session.active)) }
var denied = TriggerSession()
do {
    try denied.update(matches: [.terminal], activate: { throw TestError.denied }, deactivate: {})
    cases.append(("Activation failure propagates", false))
} catch { cases.append(("Activation failure never reports active", !denied.active)) }
for (name, passed) in cases { print("\(passed ? "PASS" : "FAIL") \(name)") }
exit(cases.allSatisfy { $0.1 } ? 0 : 1)
