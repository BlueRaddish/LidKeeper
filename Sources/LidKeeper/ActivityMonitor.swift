import AppKit
import SessionPolicy

enum ActivityMonitor {
    static func matching(_ selected: Set<ActivityTrigger>) throws -> [ActivityTrigger] {
        let bundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var processes: [TerminalProcess] = []
        if selected.contains(where: \.needsProcesses) {
            processes = TerminalProcess.parse(try processSnapshot())
        }
        return ActivityTrigger.allCases.filter { selected.contains($0) && $0.matches(processes: processes, bundles: bundles) }
    }

    private static func processSnapshot() throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-ww", "-o", "tty=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = SnapshotOutput()
        let done = DispatchSemaphore(value: 0)
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        DispatchQueue.global().async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            throw PowerError.message("Process monitoring timed out. Watching has stopped.")
        }
        guard process.terminationStatus == 0 else {
            throw PowerError.message("macOS did not allow process monitoring. Watching has stopped.")
        }
        return String(decoding: output.get(), as: UTF8.self)
    }
}

private final class SnapshotOutput {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
