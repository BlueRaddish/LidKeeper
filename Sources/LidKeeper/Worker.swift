import Foundation
import Darwin
import SessionPolicy

// Separate process retains cleanup responsibility if the UI crashes. stdin is a
// lifetime lease; a LaunchAgent also repairs a stranded global override.
func runWorker(seconds: Double, triggers: Set<ActivityTrigger> = []) -> Never {
    let power = PowerControl()
    let watching = !triggers.isEmpty
    let policy = SessionPolicy(deadline: watching ? .distantFuture : Date().addingTimeInterval(seconds))
    let owner = getppid()
    func emit(_ message: String) { print(message); fflush(stdout) }
    let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("dev.blueraddish.LidKeeper.session.lock")
    let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        emit("ERROR Another session is active, or its lock is unavailable."); exit(1)
    }
    let initial = Battery.read()
    let initialThermal = ProcessInfo.processInfo.thermalState
    if let reason = policy.stopReason(now: Date(), batteryPercent: initial.percent,
                                     onBattery: initial.onBattery,
                                     thermalCritical: initialThermal == .serious || initialThermal == .critical,
                                     ownerAlive: true) {
        emit("ERROR \(reason)"); exit(1)
    }
    var finishing = false
    func finish(_ reason: String, sleep: Bool = false, exitCode: Int32 = 0) {
        guard !finishing else { return }; finishing = true
        if let error = power.stop() {
            emit("ERROR \(error). To restore normal sleep, run: sudo pmset -a disablesleep 0")
            exit(2)
        }
        if sleep {
            do { try power.sleepNow() } catch { emit("ERROR \(error.localizedDescription)"); exit(2) }
        }
        emit("STOPPED \(reason)"); exit(exitCode)
    }
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { finish("Session interrupted") }
        source.resume(); signals.append(source)
    }
    var triggerSession = TriggerSession()
    var lastActivity = ""
    if !watching {
        do { try power.start() } catch { emit("ERROR \(error.localizedDescription)"); exit(1) }
    }
    // Read from the pipe on a dedicated thread; execute all state changes on main.
    DispatchQueue.global().async {
        while let line = readLine() {
            if line == "sleep" { DispatchQueue.main.async { finish("Sleep requested", sleep: true) }; return }
            if line == "stop" { DispatchQueue.main.async { finish("Session ended") }; return }
        }
        DispatchQueue.main.async { finish("App disconnected") }
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
    timer.setEventHandler {
        let battery = Battery.read()
        let thermal = ProcessInfo.processInfo.thermalState
        if let reason = policy.stopReason(now: Date(), batteryPercent: battery.percent,
            onBattery: battery.onBattery, thermalCritical: thermal == .serious || thermal == .critical,
            ownerAlive: getppid() == owner && kill(owner, 0) == 0) {
            finish(reason)
            return
        }
        do { try power.renewLease() } catch {
            emit("ERROR \(error.localizedDescription)")
            finish("Power state changed", exitCode: 1)
            return
        }
        if watching {
            do {
                let matches = try ActivityMonitor.matching(triggers)
                try triggerSession.update(matches: matches, activate: { try power.start() }, deactivate: {
                    if let error = power.stop() { throw PowerError.message(error) }
                })
                let activity = matches.isEmpty ? "WAITING" : "ACTIVE " + matches.map(\.title).joined(separator: ", ")
                if activity != lastActivity { emit(activity); lastActivity = activity }
            } catch {
                emit("ERROR \(error.localizedDescription)")
                finish("Watching stopped", exitCode: 1)
            }
        }
    }
    timer.resume()
    emit(watching ? "WATCHING" : "READY")
    withExtendedLifetime(signals) { dispatchMain() }
}
