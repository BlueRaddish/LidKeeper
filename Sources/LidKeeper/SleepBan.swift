import AppKit
import Foundation

// pmset's global SleepDisabled setting is the mechanism used by other working
// closed-lid utilities. Keep the privilege narrowly scoped and the active period
// leased so a crashed app does not leave the Mac unable to sleep indefinitely.
enum SleepBan {
    private static let grant = "/etc/sudoers.d/lidkeeper-disablesleep"
    private static let agentLabel = "dev.blueraddish.LidKeeper.reconcile"
    private static let staleAfter: TimeInterval = 60

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LidKeeper", isDirectory: true)
    }
    private static var lease: URL { support.appendingPathComponent("active.lease") }
    private static var agent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    static var hasLease: Bool { FileManager.default.fileExists(atPath: lease.path) }

    static var grantInstalled: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: grant),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode == 0o440
        else { return false }
        // A root:wheel 0440 sudoers file is deliberately unreadable by an
        // ordinary account. The actual pmset call is the authority check.
        return true
    }

    private static var rule: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    }

    // The only variable interpolated into the privileged shell command is the
    // local account name, restricted here to sudoers-safe characters.
    static func installGrant() throws {
        let name = NSUserName()
        guard !name.isEmpty, name.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw PowerError.message("The account name cannot be used in a safe sudoers rule.")
        }
        let staging = "/etc/sudoers.d/.lidkeeper-disablesleep.new"
        let command = "/usr/bin/printf '%s\\n' '\(rule.trimmingCharacters(in: .newlines))' > \(staging) && /bin/chmod 0440 \(staging) && /usr/sbin/visudo -cf \(staging) && /usr/bin/install -o root -g wheel -m 0440 \(staging) \(grant); result=$?; /bin/rm -f \(staging); exit $result"
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { throw PowerError.message("Could not prepare the administrator request.") }
        var details: NSDictionary?
        _ = appleScript.executeAndReturnError(&details)
        if let details { throw PowerError.message("Administrator setup failed: \(details[NSAppleScript.errorMessage] ?? "Unknown error")") }
        guard grantInstalled else { throw PowerError.message("The limited administrator rule was not installed.") }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func ensureReady() throws {
        guard grantInstalled else { throw PowerError.message("Administrator setup is required before starting a session.") }
        try installWatchdog()
    }

    private static func run(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PowerError.message("\((executable as NSString).lastPathComponent) failed (exit \(process.terminationStatus)).")
        }
    }

    static func setDisabled(_ disabled: Bool) throws {
        try run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }

    static func writeLease() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("LidKeeper active\n".utf8).write(to: lease, options: .atomic)
    }

    static func removeLease() throws {
        if hasLease { try FileManager.default.removeItem(at: lease) }
    }

    private static func installWatchdog() throws {
        guard let executable = Bundle.main.executableURL else { throw PowerError.message("Cannot locate the LidKeeper executable for crash recovery.") }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable.path, "--reconcile"],
            "RunAtLoad": true,
            "StartInterval": 20
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let domain = "gui/\(getuid())"
        // Reinstall when the app moves so the job always points at this copy.
        if let old = try? Data(contentsOf: agent), old == data {
            if (try? run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"])) != nil { return }
        }
        try data.write(to: agent, options: .atomic)
        try? run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
        try run("/bin/launchctl", ["bootstrap", domain, agent.path])
    }

    @discardableResult static func reconcile() -> Bool {
        guard hasLease else { return true }
        let modified = (try? lease.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < staleAfter { return true }
        do {
            try setDisabled(false)
            guard PowerControl.confirmsSleepDisabled(false) else { return false }
            try removeLease()
            return true
        } catch { return false }
    }
}
