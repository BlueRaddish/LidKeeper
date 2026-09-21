/// Holds controls only while at least one selected activity matches. State changes
/// commit after the OS operation succeeds so failures remain recoverable.
public struct TriggerSession {
    public private(set) var active = false
    public init() {}

    public mutating func update(matches: [ActivityTrigger], activate: () throws -> Void,
                                deactivate: () throws -> Void) throws {
        let needed = !matches.isEmpty
        if needed && !active { try activate(); active = true }
        else if !needed && active { try deactivate(); active = false }
    }
}
