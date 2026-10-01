import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

enum PowerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Battery {
    let percent: Int?
    let onBattery: Bool

    static func read() -> Battery {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return Battery(percent: nil, onBattery: true) }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = info[kIOPSCurrentCapacityKey] as? Int
            let maximum = info[kIOPSMaxCapacityKey] as? Int
            let percent = current.flatMap { value in maximum.flatMap { $0 > 0 ? value * 100 / $0 : nil } }
            return Battery(percent: percent, onBattery: info[kIOPSPowerSourceStateKey] as? String != kIOPSACPowerValue)
        }
        return Battery(percent: nil, onBattery: true)
    }
}

final class PowerControl {
    private var assertion: IOPMAssertionID = 0
    private var hasAssertion = false
    private var ownsOverride = false

    static func property(_ name: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    static func confirmsSleepDisabled(_ disabled: Bool) -> Bool {
        for attempt in 0..<5 {
            if property("SleepDisabled") == disabled { return true }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }

    func start() throws {
        guard !hasAssertion && !ownsOverride else { throw PowerError.message("Power controls are already held or still need cleanup.") }
        guard Self.property("AppleClamshellState") != nil else { throw PowerError.message("No laptop lid was detected.") }
        guard Self.property("SleepDisabled") == false else {
            throw PowerError.message("System sleep is already disabled or its state is unavailable. LidKeeper will not take over another utility's setting.")
        }
        try SleepBan.ensureReady()
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "LidKeeper session" as CFString, &assertion)
        guard result == kIOReturnSuccess else { throw failure("Prevent idle sleep", result) }
        hasAssertion = true
        do {
            try SleepBan.writeLease()
            try SleepBan.setDisabled(true)
            ownsOverride = true
            guard Self.confirmsSleepDisabled(true) else {
                throw PowerError.message("macOS did not confirm that sleep was disabled.")
            }
        } catch {
            let original = error
            if let cleanup = stop() { throw PowerError.message("\(original.localizedDescription) Cleanup failed: \(cleanup)") }
            throw original
        }
    }

    func renewLease() throws {
        guard ownsOverride else { return }
        guard Self.property("SleepDisabled") == true else {
            throw PowerError.message("macOS no longer reports sleep disabled; the session cannot be trusted.")
        }
        try SleepBan.writeLease()
    }

    @discardableResult func stop() -> String? {
        var errors: [String] = []
        // A failed enable can still have taken effect, so a lease also means cleanup is owed.
        if ownsOverride || SleepBan.hasLease {
            do {
                try SleepBan.setDisabled(false)
                guard Self.confirmsSleepDisabled(false) else {
                    throw PowerError.message("macOS did not confirm normal sleep was restored.")
                }
                ownsOverride = false
                try SleepBan.removeLease()
            } catch { errors.append(error.localizedDescription) }
        }
        if hasAssertion {
            let result = IOPMAssertionRelease(assertion)
            if result == kIOReturnSuccess { hasAssertion = false }
            else { errors.append(failure("Release idle sleep assertion", result).localizedDescription) }
        }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    func sleepNow() throws {
        if let error = stop() { throw PowerError.message(error) }
        let handle = IOPMFindPowerManagement(0)
        guard handle != 0 else { throw PowerError.message("Cannot request system sleep.") }
        defer { IOServiceClose(handle) }
        let result = IOPMSleepSystem(handle)
        guard result == kIOReturnSuccess else { throw failure("Sleep", result) }
    }

    private func failure(_ operation: String, _ code: IOReturn) -> PowerError {
        .message("\(operation) failed (\(String(format: "0x%08x", code))).")
    }

    deinit { stop() }
}
