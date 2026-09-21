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
    private var connection: io_connect_t = 0
    private var assertion: IOPMAssertionID = 0
    private var hasAssertion = false
    private var changedLid = false

    static func property(_ name: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    func start() throws {
        guard connection == 0 && !hasAssertion && !changedLid else {
            throw PowerError.message("Power controls are already held or still need cleanup.")
        }
        guard Self.property("AppleClamshellState") != nil else {
            throw PowerError.message("No laptop lid was detected.")
        }
        guard Self.property("SleepDisabled") == false else {
            throw PowerError.message("System sleep is disabled or its state is unavailable. If you previously used pmset, restore it with: sudo pmset -a disablesleep 0")
        }
        connection = IOPMFindPowerManagement(0)
        guard connection != 0 else { throw PowerError.message("Cannot connect to macOS power management.") }
        do {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "LidKeeper session" as CFString, &assertion)
            guard result == kIOReturnSuccess else { throw failure("Prevent idle sleep", result) }
            hasAssertion = true
            try setLidDisabled(true)
            changedLid = true
        } catch {
            _ = stop()
            throw error
        }
    }

    // Private selector 12 is kPMSetClamshellSleepState in Apple's IOPMLibDefs.h.
    // Unlike SleepDisabled, this only changes the kernel's clamshell sleep mask.
    // It shares the powerd bit: this is experimental, not an independently owned assertion.
    private func setLidDisabled(_ disabled: Bool) throws {
        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(connection, 12, &input, 1, nil, nil)
        guard result == kIOReturnSuccess else { throw failure("Change lid sleep", result) }
    }

    @discardableResult func stop() -> String? {
        var error: String?
        if changedLid {
            do { try setLidDisabled(false); changedLid = false }
            catch let failure { error = failure.localizedDescription }
        }
        if hasAssertion {
            let result = IOPMAssertionRelease(assertion)
            if result == kIOReturnSuccess { hasAssertion = false }
            else { error = error ?? failure("Release idle sleep assertion", result).localizedDescription }
        }
        if !changedLid && connection != 0 { IOServiceClose(connection); connection = 0 }
        return error
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
        .message("\(operation) failed (\(String(format: "0x%08x", code))). This macOS version may not support the experimental lid control.")
    }

    deinit { stop() }
}
