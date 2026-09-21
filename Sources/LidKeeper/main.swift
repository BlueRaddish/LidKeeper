import AppKit
import Foundation
import SessionPolicy

// Broken worker pipes should surface as write errors, not terminate the UI.
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--watch") {
    let values = CommandLine.arguments.last?.split(separator: ",").map(String.init) ?? []
    let triggers = Set(values.compactMap(ActivityTrigger.init(rawValue:)))
    guard !triggers.isEmpty, triggers.count == Set(values).count else { exit(64) }
    runWorker(seconds: 0, triggers: triggers)
}

if CommandLine.arguments.contains("--diagnose-triggers") {
    do {
        let matches = try ActivityMonitor.matching(Set(ActivityTrigger.allCases))
        print(matches.map(\.title).joined(separator: "\n"))
    } catch { print(error.localizedDescription); exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("--worker") {
    guard let last = CommandLine.arguments.last, let seconds = Double(last),
          seconds.isFinite, seconds > 0, seconds <= 28_800 else { exit(64) }
    runWorker(seconds: seconds)
}

if CommandLine.arguments.contains("--diagnose") {
    let battery = Battery.read()
    print("Lid present: \(PowerControl.property("AppleClamshellState") != nil)")
    print("Global sleep disabled: \(String(describing: PowerControl.property("SleepDisabled")))")
    print("Battery: \(battery.percent.map(String.init) ?? "unknown")%; on battery: \(battery.onBattery)")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var item: NSStatusItem!
    private var worker: Process?
    private var input: Pipe?
    private var status = "Normal lid sleep"
    private var active = false
    private var quitting = false
    private var buffer = ""
    private var observer: NSObjectProtocol?
    private var watching = false
    private var timedMinutes: Int?
    private var matchingTriggers: Set<String> = []
    private var selectedTriggers = Set<ActivityTrigger>(
        (UserDefaults.standard.stringArray(forKey: "selectedTriggers") ?? ["terminal"])
            .compactMap(ActivityTrigger.init(rawValue:)))

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one UI should own the shared lid setting.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blueraddish.LidKeeper").count > 1 {
            NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.stop() }
        rebuild()
    }

    private func rebuild() {
        item.button?.image = NSImage(systemSymbolName: active ? "laptopcomputer.and.arrow.down" : "laptopcomputer", accessibilityDescription: "LidKeeper")
        item.button?.title = watching ? (active ? " Auto · Awake" : " Auto · Waiting") : (active ? " On" : "")
        item.button?.toolTip = watching
            ? (active ? "LidKeeper: trigger mode is on and keeping your Mac awake" : "LidKeeper: trigger mode is on, waiting for a selected activity")
            : "LidKeeper: trigger mode is off"
        let menu = NSMenu()
        let title = NSMenuItem(title: "LidKeeper · Experimental", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let triggerLabel = watching
            ? "Trigger-Based: On · \(active ? "Keeping Awake" : "Waiting")"
            : "Trigger-Based: Off"
        let triggerItem = NSMenuItem(title: triggerLabel, action: nil, keyEquivalent: "")
        triggerItem.state = watching ? .on : .off
        let triggersMenu = NSMenu()
        triggersMenu.autoenablesItems = false
        let enable = NSMenuItem(title: watching ? "Stop Watching" : "Watch Selected Triggers", action: #selector(toggleWatching), keyEquivalent: "")
        enable.target = self
        enable.isEnabled = watching || (worker == nil && !selectedTriggers.isEmpty)
        enable.state = watching ? .on : .off
        triggersMenu.addItem(enable)
        triggersMenu.addItem(.separator())
        for (index, trigger) in ActivityTrigger.allCases.enumerated() {
            let label = trigger.title + (matchingTriggers.contains(trigger.title) ? " · Running" : "")
            let choice = NSMenuItem(title: label, action: #selector(toggleTrigger(_:)), keyEquivalent: "")
            choice.tag = index; choice.target = self
            choice.state = selectedTriggers.contains(trigger) ? .on : .off
            choice.isEnabled = worker == nil
            triggersMenu.addItem(choice)
        }
        triggersMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Keeps awake while ANY selection runs", action: nil, keyEquivalent: "")
        hint.isEnabled = false; triggersMenu.addItem(hint)
        triggerItem.submenu = triggersMenu
        menu.addItem(triggerItem)
        for (label, minutes) in [("Keep Awake for 30 Minutes", 30), ("Keep Awake for 1 Hour", 60), ("Keep Awake for 2 Hours", 120)] {
            let choice = NSMenuItem(title: label, action: #selector(start(_:)), keyEquivalent: "")
            choice.state = timedMinutes == minutes ? (active ? .on : .mixed) : .off
            choice.tag = minutes; choice.target = self; menu.addItem(choice)
        }
        if worker != nil {
            let stopItem = NSMenuItem(title: "End Session", action: #selector(stop), keyEquivalent: "")
            stopItem.target = self; menu.addItem(stopItem)
        }
        let sleep = NSMenuItem(title: "Sleep Now", action: #selector(sleepNow), keyEquivalent: "s")
        sleep.target = self; menu.addItem(sleep)
        menu.addItem(.separator())
        let safety = NSMenuItem(title: "Stops at 20% Battery or High Heat", action: nil, keyEquivalent: "")
        let safetyMenu = NSMenu()
        for (label, tag) in [("Battery Cutoff: 20%…", 0), ("High Heat Protection…", 1)] {
            let detail = NSMenuItem(title: label, action: #selector(showSafetyDetails(_:)), keyEquivalent: "")
            detail.target = self; detail.tag = tag; detail.state = .on
            safetyMenu.addItem(detail)
        }
        safety.submenu = safetyMenu
        menu.addItem(safety)
        let about = NSMenuItem(title: "About & Limitations…", action: #selector(about), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let quit = NSMenuItem(title: "Quit LidKeeper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    @objc private func start(_ sender: NSMenuItem) {
        if worker != nil && timedMinutes == sender.tag { stop(); return }
        launchWorker(seconds: sender.tag * 60, watch: false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(start(_:)) {
            return worker == nil || timedMinutes == menuItem.tag
        }
        return true
    }

    @objc private func showSafetyDetails(_ sender: NSMenuItem) {
        let alert = NSAlert()
        if sender.tag == 0 {
            alert.messageText = "Battery cutoff is enabled"
            alert.informativeText = "At 20% battery or below, LidKeeper ends the session and restores normal sleep eligibility. This cutoff applies while running on battery, not while charging. Trigger watching stays off until you enable it again. The threshold is fixed at 20% in this version."
        } else {
            alert.messageText = "High heat protection is enabled"
            alert.informativeText = "LidKeeper ends the session when macOS reports serious or critical thermal pressure. This applies on both battery and charger. It uses macOS's thermal status, not a fixed temperature. Trigger watching stays off until you enable it again. This protection is always enabled."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleTrigger(_ sender: NSMenuItem) {
        guard worker == nil else { return }
        let trigger = ActivityTrigger.allCases[sender.tag]
        if selectedTriggers.contains(trigger) { selectedTriggers.remove(trigger) }
        else { selectedTriggers.insert(trigger) }
        UserDefaults.standard.set(selectedTriggers.map(\.rawValue).sorted(), forKey: "selectedTriggers")
        rebuild()
    }

    @objc private func toggleWatching() {
        if watching { stop() }
        else if !selectedTriggers.isEmpty { launchWorker(seconds: 0, watch: true) }
    }

    private func launchWorker(seconds: Int, watch: Bool) {
        guard worker == nil else { return }
        if !UserDefaults.standard.bool(forKey: "acknowledgedExperimentalControl") {
            let alert = NSAlert()
            alert.messageText = "Keep working with the lid closed"
            alert.informativeText = "LidKeeper uses a private macOS lid control. Explicit sleep remains available by design, but lid and power-button behavior need testing on your Mac. Keep your Mac ventilated while closed. Sessions stop at 20% battery or high heat. Timed sessions expire; trigger-based sessions watch until you stop them or request sleep."
            alert.addButton(withTitle: "Start Session"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: "acknowledgedExperimentalControl")
        }
        let process = Process(), commands = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = watch ? ["--watch", selectedTriggers.map(\.rawValue).sorted().joined(separator: ",")] : ["--worker", String(seconds)]
        process.standardInput = commands; process.standardOutput = output; process.standardError = output
        buffer = ""; status = "Starting…"
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, let process, self.worker === process else { return }
                self.receive(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.worker === process else { return }
                self.worker = nil; self.input = nil; self.active = false; self.watching = false
                self.timedMinutes = nil; self.matchingTriggers = []
                if self.status == "Starting…" || self.status.hasPrefix("Awake") || self.status.hasPrefix("Watching") {
                    self.status = process.terminationStatus == 0 ? "Session ended" : "Session failed — see diagnostics"
                }
                self.rebuild()
                if self.quitting { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        do {
            try process.run()
            // Close the parent's copy of the child's stdin read end.
            commands.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            worker = process; input = commands; watching = watch
            timedMinutes = watch ? nil : seconds / 60
        } catch { status = error.localizedDescription }
        rebuild()
    }

    private func receive(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line == "READY" { active = true; status = "Awake with lid closed · session active" }
            else if line == "WATCHING" || line == "WAITING" {
                matchingTriggers = []
                active = false; status = "Watching · no selected triggers running"
            }
            else if line.hasPrefix("ACTIVE ") {
                matchingTriggers = Set(String(line.dropFirst(7)).components(separatedBy: ", "))
                active = true; status = "Awake · " + String(line.dropFirst(7))
            }
            else if line.hasPrefix("STOPPED ") { active = false; timedMinutes = nil; matchingTriggers = []; status = String(line.dropFirst(8)) }
            else if line.hasPrefix("ERROR ") {
                active = false; status = "Could not complete session"
                timedMinutes = nil; matchingTriggers = []
                let alert = NSAlert(); alert.messageText = "LidKeeper"
                alert.informativeText = String(line.dropFirst(6)); alert.runModal()
            }
        }
        rebuild()
    }

    private func command(_ value: String) {
        do { try input?.fileHandleForWriting.write(contentsOf: Data("\(value)\n".utf8)) }
        catch { status = "Worker disconnected"; rebuild() }
    }
    @objc private func stop() { command("stop") }
    @objc private func sleepNow() {
        if worker != nil { command("sleep") }
        else {
            do { try PowerControl().sleepNow() }
            catch { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
        }
    }
    @objc private func about() {
        NSWorkspace.shared.open(URL(string: "https://github.com/BlueRaddish/LidKeeper#readme")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard worker != nil else { return .terminateNow }
        quitting = true; stop(); return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
