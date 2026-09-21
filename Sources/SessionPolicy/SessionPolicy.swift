import Foundation

public struct SessionPolicy {
    public let deadline: Date
    public let batteryFloor: Int

    public init(deadline: Date, batteryFloor: Int = 20) {
        self.deadline = deadline
        self.batteryFloor = batteryFloor
    }

    public func stopReason(now: Date, batteryPercent: Int?, onBattery: Bool,
                           thermalCritical: Bool, ownerAlive: Bool) -> String? {
        if !ownerAlive { return "App disconnected" }
        if thermalCritical { return "Mac is too warm" }
        if now >= deadline { return "Session finished" }
        if onBattery {
            guard let batteryPercent else { return "Battery level unavailable" }
            if batteryPercent <= batteryFloor { return "Battery reached \(batteryFloor)%" }
        }
        return nil
    }
}
