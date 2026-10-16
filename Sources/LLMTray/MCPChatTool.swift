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
    /// The tools were listed again just now: an earlier "Allow for This
    /// Chat" may answer (else the card asks).
    var chatAllowanceUsable = true
    /// The user let it run without asking, yet it's asked: the card says why.
    var allowedButAsked = false

    /// Whether what the user allowed (always, for this chat) stands for this
    /// call: yes before outside text; after it only for reading on this Mac
    /// -- a tool the server says only reads, on a command server: what it
    /// reads comes back into the chat, its arguments go nowhere. A change, or
    /// any call to a server on the web, is asked then (adr/0027).
    var allowancesHold: Bool {
        // The hint as reviewed and as listed now: a write relisted as a read
        // doesn't pass.
        !afterOutsideText || (tool.readOnlyHint == true && server.reviewedReadOnly[tool.name] == true && server.kind == .command)
    }
}

enum MCPCallChoice: Equatable {
    case allowOnce
    case allowForChat
    /// Allowed from now on: this tool's action runs without asking (as
    /// Configure's checkbox).
    case allowAlways
    /// Every action of every tool of this server, from now on.
    case allowServerAlways
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
        // The tools listed again first (a server may change them without
        // saying so): an allowance holds only for the definition listed now,
        // and a listing that fails means asking.
        let listed = await MCPHub.shared.confirmListed(config)
        guard let again = MCPHub.shared.tool(named: name), again.config.id == config.id else {
            return .text("\(name) changed on its server; the user has to review it in Settings first. Tell the user.")
        }
        (config, tool) = again
        let request = MCPCallRequest(server: config, tool: tool, modelName: name, action: action,
                                     arguments: Self.pretty(arguments), afterOutsideText: context.outsideTextThisTurn,
                                     chatAllowanceUsable: listed)
        let allowed = MCPApproval.runsWithoutAsking(tool, arguments: arguments, config: config)
        let standing = listed && request.allowancesHold && allowed
        if !standing {
            var request = request
            request.allowedButAsked = allowed
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
            guard let now = MCPHub.shared.tool(named: name), now.tool == tool, now.config.id == config.id else {
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
