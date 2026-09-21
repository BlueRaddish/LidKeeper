import AppKit
import Foundation

// Broken worker pipes should surface as write errors, not terminate the UI.
signal(SIGPIPE, SIG_IGN)

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var worker: Process?
    private var input: Pipe?
    private var status = "Normal lid sleep"
    private var active = false
    private var quitting = false
    private var buffer = ""
    private var observer: NSObjectProtocol?

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
        item.button?.title = active ? " On" : ""
        let menu = NSMenu()
        let title = NSMenuItem(title: "LidKeeper · Experimental", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        if worker == nil {
            for (label, minutes) in [("Keep Awake for 30 Minutes", 30), ("Keep Awake for 1 Hour", 60), ("Keep Awake for 2 Hours", 120)] {
                let choice = NSMenuItem(title: label, action: #selector(start(_:)), keyEquivalent: "")
                choice.tag = minutes; choice.target = self; menu.addItem(choice)
            }
        } else {
            let stopItem = NSMenuItem(title: "End Session", action: #selector(stop), keyEquivalent: "")
            stopItem.target = self; menu.addItem(stopItem)
        }
        let sleep = NSMenuItem(title: "Sleep Now", action: #selector(sleepNow), keyEquivalent: "s")
        sleep.target = self; menu.addItem(sleep)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stops at 20% battery or high heat", action: nil, keyEquivalent: ""))
        let about = NSMenuItem(title: "About & Limitations…", action: #selector(about), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let quit = NSMenuItem(title: "Quit LidKeeper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    @objc private func start(_ sender: NSMenuItem) {
        guard worker == nil else { return }
        if !UserDefaults.standard.bool(forKey: "acknowledgedExperimentalControl") {
            let alert = NSAlert()
            alert.messageText = "Keep working with the lid closed"
            alert.informativeText = "LidKeeper uses a private macOS lid control. Explicit sleep remains available by design, but lid and power-button behavior need testing on your Mac. Other keep-awake apps or macOS can override this shared control. Keep your Mac ventilated while closed. Sessions stop at 20% battery, high heat, or the time limit."
            alert.addButton(withTitle: "Start Session"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: "acknowledgedExperimentalControl")
        }
        let process = Process(), commands = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--worker", String(sender.tag * 60)]
        process.standardInput = commands; process.standardOutput = output; process.standardError = output
        buffer = ""; status = "Starting…"
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.receive(text) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.worker = nil; self.input = nil; self.active = false
                if self.status == "Starting…" || self.status.hasPrefix("Awake") {
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
            worker = process; input = commands
        } catch { status = error.localizedDescription }
        rebuild()
    }

    private func receive(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line == "READY" { active = true; status = "Awake with lid closed · session active" }
            else if line.hasPrefix("STOPPED ") { active = false; status = String(line.dropFirst(8)) }
            else if line.hasPrefix("ERROR ") {
                active = false; status = "Could not complete session"
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
