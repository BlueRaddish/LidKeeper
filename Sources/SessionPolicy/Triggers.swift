import Foundation

public enum ActivityTrigger: String, CaseIterable {
    case terminal, codexCLI, claudeCLI, codexApp, claudeApp, vscode, cursor

    public static func parseSelection(_ value: String) -> Set<ActivityTrigger>? {
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
        let triggers = names.compactMap { ActivityTrigger(rawValue: String($0)) }
        guard !triggers.isEmpty, triggers.count == names.count,
              Set(triggers).count == names.count else { return nil }
        return Set(triggers)
    }

    public var title: String {
        switch self {
        case .terminal: return "Terminal Sessions"
        case .codexCLI: return "Codex CLI (in a terminal)"
        case .claudeCLI: return "Claude Code (in a terminal)"
        case .codexApp: return "Codex App"
        case .claudeApp: return "Claude Desktop"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        }
    }

    public var needsProcesses: Bool { [.terminal, .codexCLI, .claudeCLI].contains(self) }

    public func matches(processes: [TerminalProcess], bundles: Set<String>) -> Bool {
        switch self {
        case .terminal:
            return processes.contains { $0.hasTerminal && ["sh", "bash", "zsh", "fish", "nu", "xonsh", "tcsh", "csh"].contains($0.name) }
        case .codexCLI: return processes.contains { $0.hasTerminal && $0.name == "codex" }
        case .claudeCLI: return processes.contains { $0.hasTerminal && $0.name == "claude" }
        case .codexApp: return bundles.contains("com.openai.codex")
        case .claudeApp: return bundles.contains("com.anthropic.claudefordesktop")
        case .vscode: return bundles.contains("com.microsoft.VSCode")
        case .cursor: return bundles.contains("com.todesktop.230313mzl4w4u92")
        }
    }
}

public struct TerminalProcess {
    public let name: String
    public let hasTerminal: Bool

    public init(name: String, hasTerminal: Bool) {
        self.name = name; self.hasTerminal = hasTerminal
    }

    // ps supplies tty and executable path only, never command arguments.
    public static func parse(_ output: String) -> [TerminalProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2 else { return nil }
            let path = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let name = (path as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return TerminalProcess(name: name, hasTerminal: fields[0] != "??" && fields[0] != "?" && !fields[0].hasSuffix("-"))
        }
    }
}
