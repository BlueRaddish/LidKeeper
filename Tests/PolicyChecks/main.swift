import Foundation
import SessionPolicy

let now = Date(timeIntervalSince1970: 1_000)
func reason(battery: Int? = 80, onBattery: Bool = true, hot: Bool = false,
            alive: Bool = true, seconds: Double = 60) -> String? {
    SessionPolicy(deadline: now.addingTimeInterval(seconds)).stopReason(
        now: now, batteryPercent: battery, onBattery: onBattery,
        thermalCritical: hot, ownerAlive: alive)
}
let cases: [(String, Bool)] = [
    ("Healthy session continues", reason() == nil),
    ("Stops at battery floor", reason(battery: 20) != nil),
    ("Stops below battery floor", reason(battery: 19) != nil),
    ("Continues above battery floor", reason(battery: 21) == nil),
    ("Low battery on charger continues", reason(battery: 5, onBattery: false) == nil),
    ("Unknown battery fails closed", reason(battery: nil) != nil),
    ("Deadline ends session", reason(seconds: 0) != nil),
    ("App disconnect ends session", reason(alive: false) != nil),
    ("High heat stops even on charger", reason(onBattery: false, hot: true) != nil)
]
for (name, passed) in cases { print("\(passed ? "PASS" : "FAIL") \(name)") }
exit(cases.allSatisfy { $0.1 } ? 0 : 1)
