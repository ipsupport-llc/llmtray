import Foundation
import LLMTrayCore

/// What the card asks about one MCP call (adr/0027).
struct MCPCallRequest {
    let server: MCPServerConfig
    let tool: MCP.Tool
    let modelName: String
    let action: String?
    /// The arguments, pretty-printed: shown in full.
    let arguments: String
    /// Proposed right after outside text in the turn: flagged, and "Allow
    /// for This Chat" isn't offered.
    let afterOutsideText: Bool
}

enum MCPCallChoice: Equatable {
    case allowOnce
    case allowForChat
    case deny
}

/// One tool of an MCP server the user added (adr/0027): declared as the
/// server gives it, every call through the card unless the user let it
/// run without asking (and no outside text came this turn).
@MainActor
final class MCPChatTool: ChatTool {
    let name: String

    init(name: String) {
        self.name = name
    }

    var definition: [String: Any] {
        MCPHub.shared.definition(model: name) ?? ["type": "function", "function": ["name": name, "description": "Unavailable.",
                                                                                   "parameters": ["type": "object", "properties": [String: Any]()]]]
    }

    func isOffered(_ settings: ChatSettings) -> Bool {
        settings.mcpChat && MCPHub.shared.tool(named: name) != nil
    }

    func run(_ arguments: [String: Any], context: ToolContext) async -> ToolResult {
        guard var (config, tool) = MCPHub.shared.tool(named: name) else {
            return .text("\(name) isn't available any more (its server was switched off or changed). Answer without it.")
        }
        let action = MCPApproval.action(of: tool, arguments: arguments)
        // An HTTP server has no change stream (v1): its tools are listed
        // again before an allowance stands for a call.
        if !context.outsideTextThisTurn, config.kind == .url,
           MCPApproval.runsWithoutAsking(tool, arguments: arguments, config: config) {
            await MCPHub.shared.confirmListed(config)
            guard let again = MCPHub.shared.tool(named: name) else {
                return .text("\(name) changed on its server; the user has to review it in Settings first. Tell the user.")
            }
            (config, tool) = again
        }
        let standing = !context.outsideTextThisTurn && MCPApproval.runsWithoutAsking(tool, arguments: arguments, config: config)
        if !standing {
            let request = MCPCallRequest(server: config, tool: tool, modelName: name, action: action,
                                         arguments: Self.pretty(arguments), afterOutsideText: context.outsideTextThisTurn)
            guard let ask = context.askMCP else {
                return .mcp(MCPCallRecord(server: config.name, tool: tool.name, action: action, arguments: arguments, outcome: .denied),
                            text: "Not run: the user couldn't be asked about it here.", refused: true)
            }
            let choice = await ask(request)
            guard let choice, choice != .deny else {
                let record = MCPCallRecord(server: config.name, tool: tool.name, action: action, arguments: arguments, outcome: .denied)
                return .mcp(record, text: choice == nil ? "Not run: the user stopped it."
                            : "Not run: the user didn't allow this call. Don't ask again unless the user does.", refused: true)
            }
            // Asked and allowed: the definition must still be the one shown.
            guard MCPHub.shared.tool(named: name)?.tool == tool else {
                return .text("\(name) changed on its server while the user was asked; nothing ran. Tell the user.")
            }
        }
        let outcome = await MCPHub.shared.call(config, tool, arguments: arguments)
        switch outcome {
        case .done(let text, let isError):
            return .mcp(MCPCallRecord(server: config.name, tool: tool.name, action: action, arguments: arguments, outcome: isError ? .failed : .done),
                        text: text, refused: false)
        case .unknown:
            return .mcp(MCPCallRecord(server: config.name, tool: tool.name, action: action, arguments: arguments, outcome: .unknown),
                        text: MCP.unknownOutcomeText, refused: false)
        case .notSent(let why):
            return .mcp(MCPCallRecord(server: config.name, tool: tool.name, action: action, arguments: arguments, outcome: .notSent),
                        text: "Not run: \(why). Nothing happened.", refused: false)
        }
    }

    static func pretty(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
