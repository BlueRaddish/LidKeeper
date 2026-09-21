import Foundation

/// Pipe reads can split both lines and UTF-8 characters. Decode complete lines
/// only, retaining at most one bounded partial line between reads.
public struct WorkerMessages {
    private var pending = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        if pending.count > 65_536 { pending.removeAll(keepingCapacity: false) }
        return lines
    }
}
