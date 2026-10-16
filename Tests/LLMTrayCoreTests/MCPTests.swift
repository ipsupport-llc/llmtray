import XCTest
@testable import LLMTrayCore

final class MCPTests: XCTestCase {
    // MARK: Protocol

    static let mailTools: [String: Any] = ["tools": [
        ["name": "read", "description": "Read mail.", "annotations": ["readOnlyHint": true, "title": "Read mail"],
         "inputSchema": ["type": "object", "required": ["action"],
                         "properties": ["action": ["type": "string", "enum": ["list_messages", "read_message"]],
                                        "args": ["type": "object"]]]],
        ["name": "ping_me", "description": "No schema."],
    ], "nextCursor": "p2"]

    func testToolsAreReadWithHintsActionsAndCursor() {
        let page = MCP.parseTools(Self.mailTools)
        XCTAssertEqual(page.next, "p2")
        XCTAssertEqual(page.tools.map(\.name), ["read", "ping_me"])
        let read = page.tools[0]
        XCTAssertEqual(read.readOnlyHint, true)
        XCTAssertEqual(read.title, "Read mail")
        XCTAssertEqual(read.actionField?.name, "action")
        XCTAssertEqual(read.actionField?.values, ["list_messages", "read_message"])
        XCTAssertNil(page.tools[1].actionField)
        XCTAssertEqual(page.tools[1].inputSchema["type"] as? String, "object")
    }

    func testDefinitionHashFollowsWhatWasReviewed() {
        let tool = MCP.parseTools(Self.mailTools).tools[0]
        var changed = tool
        XCTAssertEqual(tool.definitionHash, changed.definitionHash)
        changed.description += " Also deletes."
        XCTAssertNotEqual(tool.definitionHash, changed.definitionHash)
        changed = tool
        changed.readOnlyHint = false   // a hint isn't part of what was reviewed
        XCTAssertEqual(tool.definitionHash, changed.definitionHash)
    }

    func testResultTextJoinsBoundsAndNamesOtherParts() {
        let r = MCP.resultText(["content": [["type": "text", "text": "a"], ["type": "image", "data": "x"], ["type": "text", "text": "b"]]])
        XCTAssertEqual(r.text, "a\nb\n[Not shown: 1 image.]")
        XCTAssertFalse(r.isError)
        let long = MCP.resultText(["content": [["type": "text", "text": String(repeating: "x", count: 50)]]], limit: 10)
        XCTAssertEqual(long.text, "xxxxxxxxxx\n[Cut: 40 more characters.]")
        let structured = MCP.resultText(["structuredContent": ["b": 1, "a": "x"], "isError": true])
        XCTAssertEqual(structured.text, #"{"a":"x","b":1}"#)
        XCTAssertTrue(structured.isError)
        XCTAssertEqual(MCP.resultText([:]).text, "(no output)")
    }

    func testMessagesParse() {
        let reply = MCP.Message.parse(Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8))
        XCTAssertEqual(reply.first?.id, 3)
        XCTAssertNil(reply.first?.method)
        let ping = MCP.Message.parse(Data(#"{"jsonrpc":"2.0","id":"s1","method":"ping"}"#.utf8))
        XCTAssertEqual(ping.first?.method, "ping")
        XCTAssertEqual(ping.first?.rawID as? String, "s1")
        XCTAssertTrue(MCP.Message.parse(Data(#"{"id":1,"result":{}}"#.utf8)).isEmpty)   // not JSON-RPC 2.0
        let error = MCP.Message.parse(Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"nope"}}"#.utf8))
        XCTAssertEqual(error.first?.error?.message, "nope")
    }

    // MARK: Names and approvals

    func testServerKeys() {
        XCTAssertEqual(MCPNames.serverKey(for: "Apple Mail, Calendar & Notes", taken: []), "apple_mail_calendar")
        XCTAssertEqual(MCPNames.serverKey(for: "Почта", taken: []), "server1")
        XCTAssertEqual(MCPNames.serverKey(for: "Почта", taken: ["server1"]), "server2")
        XCTAssertEqual(MCPNames.serverKey(for: "mail", taken: ["mail"]), "mail2")
        XCTAssertEqual(MCPNames.serverKey(for: "3d tools", taken: []), "s3d_tools")
    }

    func testToolNamesAreUniqueAndAllowed() {
        XCTAssertEqual(MCPNames.toolName(server: "mail", tool: "read", taken: []), "mail_read")
        XCTAssertEqual(MCPNames.toolName(server: "mail", tool: "read.all/now", taken: []), "mail_read_all_now")
        // `a_b` + `c` and `a` + `b_c` meet: the second gets a number.
        let first = MCPNames.toolName(server: "a_b", tool: "c", taken: [])
        XCTAssertEqual(MCPNames.toolName(server: "a", tool: "b_c", taken: [first]), "a_b_c_2")
        let long = MCPNames.toolName(server: "srv", tool: String(repeating: "t", count: 80), taken: [])
        XCTAssertEqual(long.count, 64)
        let clash = MCPNames.toolName(server: "srv", tool: String(repeating: "t", count: 80), taken: [long])
        XCTAssertEqual(clash.count, 64)
        XCTAssertTrue(clash.hasSuffix("_2"))
    }

    func testRunWithoutAskingIsPerActionAndBoundToTheHash() {
        let read = MCP.parseTools(Self.mailTools).tools[0]
        var config = MCPServerConfig(name: "Mail", key: "mail", kind: .command)
        let list: [String: Any] = ["action": "list_messages"]
        XCTAssertFalse(MCPApproval.runsWithoutAsking(read, arguments: list, config: config))   // not reviewed
        config.reviewed["read"] = read.definitionHash
        XCTAssertFalse(MCPApproval.runsWithoutAsking(read, arguments: list, config: config))   // not allowed
        config.runWithoutAsking["read"] = read.definitionHash   // the whole tool: not enough for one with actions
        XCTAssertFalse(MCPApproval.runsWithoutAsking(read, arguments: list, config: config))
        config.runWithoutAsking["read#list_messages"] = read.definitionHash
        XCTAssertTrue(MCPApproval.runsWithoutAsking(read, arguments: list, config: config))
        XCTAssertFalse(MCPApproval.runsWithoutAsking(read, arguments: ["action": "read_message"], config: config))
        XCTAssertFalse(MCPApproval.runsWithoutAsking(read, arguments: [:], config: config))
        var changed = read
        changed.description = "Read and send mail."
        XCTAssertFalse(MCPApproval.runsWithoutAsking(changed, arguments: list, config: config))
        // A plain tool: allowed whole.
        let plain = MCP.parseTools(Self.mailTools).tools[1]
        config.reviewed["ping_me"] = plain.definitionHash
        config.runWithoutAsking["ping_me"] = plain.definitionHash
        XCTAssertTrue(MCPApproval.runsWithoutAsking(plain, arguments: [:], config: config))
    }

    func testUpdateSources() {
        XCTAssertEqual(MCPSource.githubRelease(url: "https://github.com/ipsupport-llc/apple-mail-mcp/releases/latest/download/apple-mail-mcp.mcpb"),
                       .githubRelease(owner: "ipsupport-llc", repo: "apple-mail-mcp", asset: "apple-mail-mcp.mcpb"))
        XCTAssertNil(MCPSource.githubRelease(url: "https://example.com/a.mcpb"))
        XCTAssertTrue(MCPSource.isNewer("v1.5.0", than: "1.4.0"))
        XCTAssertTrue(MCPSource.isNewer("1.10", than: "1.9.3"))
        XCTAssertFalse(MCPSource.isNewer("1.4.0", than: "1.4"))
        XCTAssertFalse(MCPSource.isNewer("1.4.0", than: nil))
        XCTAssertFalse(MCPSource.isNewer("nightly", than: "1.0"))
    }

    func testSecretLookingNames() {
        XCTAssertTrue(MCPServerConfig.looksSecret("GITHUB_TOKEN"))
        XCTAssertTrue(MCPServerConfig.looksSecret("Authorization"))
        XCTAssertFalse(MCPServerConfig.looksSecret("GCS_BUCKET"))
    }

    // MARK: Trust

    func testMCPTextIsOutsideText() {
        var state = ToolTrust.TurnState()
        XCTAssertFalse(state.hasOutsideText)
        state.record(.mcp)
        XCTAssertTrue(state.hasUntrustedText)
        XCTAssertTrue(state.hasFileText)
        XCTAssertTrue(state.hasToolText)
        XCTAssertFalse(ToolTrust.allowsGuarded(state))
        XCTAssertTrue(ToolTrust.allows(.mcp, state))
        XCTAssertEqual(ToolTrust.refusalText(for: .guarded, state), ToolTrust.mcpRefusal)
        // A web search beside a mail read is refused up front; the read runs.
        let refused = ToolTrust.refusedUpFront([(id: "w", kind: .guarded), (id: "m", kind: .mcp)], state: ToolTrust.TurnState())
        XCTAssertEqual(refused, ["w"])
        var web = ToolTrust.TurnState()
        web.record(.guarded)
        XCTAssertTrue(web.hasOutsideText)
    }

    // MARK: Import

    func testPastedConfigs() throws {
        let full = try MCPImport.parseConfig("""
        {"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@x/fs", "/tmp"], "env": {"A": 1}},
                        "remote": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer t"}},
                        "broken": {"nothing": true}}}
        """)
        XCTAssertEqual(full.map(\.name), ["fs", "remote"])
        XCTAssertEqual(full[0].arguments, ["-y", "@x/fs", "/tmp"])
        XCTAssertEqual(full[0].environment, ["A": "1"])
        XCTAssertEqual(full[1].kind, .url)
        XCTAssertEqual(full[1].headers["Authorization"], "Bearer t")
        // A README fragment without the outer braces.
        let fragment = try MCPImport.parseConfig(#""weather": {"command": "uvx", "args": ["weather"]}"#)
        XCTAssertEqual(fragment.first?.name, "weather")
        XCTAssertThrowsError(try MCPImport.parseConfig("not json"))
        XCTAssertThrowsError(try MCPImport.parseConfig(#"{"mcpServers": {}}"#))
    }

    func testBundleManifest() throws {
        let manifest = """
        {"name": "apple-mail-mcp", "display_name": "Apple Mail", "description": "Mail.",
         "server": {"mcp_config": {"command": "/usr/bin/osascript", "args": ["-l", "JavaScript", "${__dirname}/server/a.js", "${user_config.limit}"]}},
         "user_config": {"limit": {"title": "Limit", "type": "number", "default": 20}},
         "compatibility": {"platforms": ["darwin"]}}
        """
        let found = try MCPImport.parseManifest(Data(manifest.utf8), folder: "/b")
        XCTAssertEqual(found.name, "Apple Mail")
        XCTAssertEqual(found.command, "/usr/bin/osascript")
        XCTAssertEqual(found.asks.map(\.key), ["limit"])
        XCTAssertEqual(found.asks.first?.defaultValue, "20")
        XCTAssertEqual(found.asks.first?.kind, .number)
        XCTAssertEqual(MCPImport.fill("${user_config.dir}", folder: "/b", home: "/h", answers: ["dir": "${HOME}/Downloads"]), "/h/Downloads")
        XCTAssertEqual(MCPImport.text(true), "true")
        XCTAssertEqual(MCPImport.text(false), "false")
        XCTAssertEqual(MCPImport.text(0), "0")
        XCTAssertEqual(MCPImport.text(2.5), "2.5")
        XCTAssertEqual(found.workingDirectory, "/b")
        XCTAssertEqual(MCPImport.fill(found.arguments[2], folder: "/b", home: "/h", answers: [:]), "/b/server/a.js")
        XCTAssertEqual(MCPImport.fill(found.arguments[3], folder: "/b", home: "/h", answers: ["limit": "5"]), "5")
        let other = manifest.replacingOccurrences(of: "${user_config.limit}", with: "${DOCUMENTS}")
        XCTAssertThrowsError(try MCPImport.parseManifest(Data(other.utf8), folder: "/b")) {
            XCTAssertEqual($0 as? MCPImport.Failure, .unsupported("${DOCUMENTS}"))
        }
        let windows = manifest.replacingOccurrences(of: #"["darwin"]"#, with: #"["win32"]"#)
        XCTAssertThrowsError(try MCPImport.parseManifest(Data(windows.utf8), folder: "/b"))
    }

    func testBundleUnpackRefusesEscapes() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3 to make the archives") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func zip(_ name: String, _ entries: [(String, String)]) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let script = "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w')\n"
                + entries.map { "z.writestr(\($0.0.debugDescription), \($0.1.debugDescription))\n" }.joined() + "z.close()\n"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-I", "-c", script, url.path]
            try p.run()
            p.waitUntilExit()
            return url
        }
        let good = try zip("good.mcpb", [("manifest.json", "{}"), ("server/a.js", "x")])
        let out = dir.appendingPathComponent("good")
        try MCPImport.unpackBundle(good, into: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("server/a.js").path))
        let evil = try zip("evil.mcpb", [("manifest.json", "{}"), ("../escaped.txt", "x")])
        XCTAssertThrowsError(try MCPImport.unpackBundle(evil, into: dir.appendingPathComponent("evil")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("escaped.txt").path))
        let big = try zip("big.mcpb", [("manifest.json", "{}"), ("blob", String(repeating: "x", count: 4096))])
        XCTAssertThrowsError(try MCPImport.unpackBundle(big, into: dir.appendingPathComponent("big"), maxBytes: 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("big").path))
        let empty = try zip("empty.mcpb", [("readme.txt", "x")])
        XCTAssertThrowsError(try MCPImport.unpackBundle(empty, into: dir.appendingPathComponent("empty")))
    }

    // MARK: Registry

    func testRegistryEntriesOfferWhatRunsHere() {
        let json = """
        {"servers": [
          {"server": {"name": "io.github.a/remote", "title": "Remote", "description": "R", "version": "1",
                      "remotes": [{"type": "streamable-http", "url": "https://r.example/mcp",
                                   "headers": [{"name": "Authorization", "isSecret": true, "isRequired": true}]}]},
           "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}},
          {"server": {"name": "io.github.b/npm", "description": "N", "version": "2",
                      "packages": [{"registryType": "npm", "identifier": "@b/srv", "version": "2.0.0", "transport": {"type": "stdio"},
                                    "environmentVariables": [{"name": "B_TOKEN", "isRequired": true}]}]},
           "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}},
          {"server": {"name": "io.github.c/docker", "description": "D", "version": "1",
                      "packages": [{"registryType": "oci", "identifier": "c/srv", "transport": {"type": "stdio"}}]},
           "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}},
          {"server": {"name": "io.github.d/gone", "description": "G", "version": "1",
                      "remotes": [{"type": "streamable-http", "url": "https://g.example"}]},
           "_meta": {"io.modelcontextprotocol.registry/official": {"status": "deleted"}}}
        ], "metadata": {"nextCursor": "c1"}}
        """
        let page = MCPRegistry.parse(Data(json.utf8), available: ["npx"])
        XCTAssertEqual(page.next, "c1")
        XCTAssertEqual(page.entries.map(\.name), ["io.github.a/remote", "io.github.b/npm", "io.github.c/docker"])
        guard case .remote(let url, let headers)? = page.entries[0].installs.first else { return XCTFail() }
        XCTAssertEqual(url, "https://r.example/mcp")
        XCTAssertEqual(headers.first?.sensitive, true)
        XCTAssertEqual(page.entries[1].title, "npm")
        let found = MCPRegistry.found(page.entries[1], page.entries[1].installs[0], runnerPath: { $0 == "npx" ? "/opt/bin/npx" : nil })
        XCTAssertEqual(found?.command, "/opt/bin/npx")
        XCTAssertEqual(found?.arguments, ["-y", "@b/srv@2.0.0"])
        XCTAssertEqual(found?.asks.first?.sensitive, true)   // B_TOKEN looks secret
        XCTAssertTrue(page.entries[2].installs.isEmpty)
        XCTAssertEqual(page.entries[2].needs, "Docker")
        XCTAssertEqual(MCPRegistry.parse(Data(json.utf8), available: []).entries[1].needs, "Node (npx)")
        XCTAssertTrue(MCPRegistry.searchURL("mail").absoluteString.contains("version=latest"))
        XCTAssertTrue(MCPRegistry.verifyBundle(Data("x".utf8), sha256: "2D711642B726B04401627CA9FBAC32F5C8530FB1903CC4DB02258717921A4881"))
        XCTAssertFalse(MCPRegistry.verifyBundle(Data("y".utf8), sha256: "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"))
    }

    // MARK: A live server (a script speaking the protocol)

    static let fakeServer = """
    import sys, json, time
    for line in sys.stdin:
        m = json.loads(line)
        i, method = m.get("id"), m.get("method")
        def send(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": m["params"]["protocolVersion"],
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
        elif method == "tools/list":
            cursor = (m.get("params") or {}).get("cursor")
            if cursor is None:
                send({"jsonrpc": "2.0", "id": i, "result": {"tools": [{"name": "echo", "description": "Echo.",
                      "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}], "nextCursor": "2"}})
            else:
                send({"jsonrpc": "2.0", "id": i, "result": {"tools": [{"name": "slow", "description": "Slow."}]}})
        elif method == "tools/call":
            p = m["params"]
            if p["name"] == "slow":
                time.sleep(5)
            sys.stderr.write("called " + p["name"] + "\\n"); sys.stderr.flush()
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            send({"jsonrpc": "2.0", "id": i, "result": {"content": [{"type": "text", "text": "echo: " + str(p.get("arguments", {}).get("text"))}]}})
        elif i is not None:
            send({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "no"}})
    """

    func testClientAgainstAStdioServer() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3 for the fake server") }
        let log = LogBox()
        let transport = MCPStdioTransport(executable: python, arguments: ["-I", "-c", Self.fakeServer],
                                          environment: MCPStdioTransport.environment(adding: ["FAKE": "1"]),
                                          workingDirectory: NSTemporaryDirectory(), onLog: { log.add($0) })
        let client = MCPClient(transport: transport)
        let changed = LogBox()
        await client.setToolsChanged { changed.add("changed") }
        let info = try await client.start()
        XCTAssertEqual(info.name, "fake")
        XCTAssertEqual(info.protocolVersion, MCP.protocolVersions[0])
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo", "slow"])
        let outcome = await client.call("echo", arguments: ["text": "hi"])
        XCTAssertEqual(outcome, .result(text: "echo: hi", isError: false))
        // Past the time limit: unknown, never retried.
        let slow = await client.call("slow", arguments: [:], timeout: 0.5)
        XCTAssertEqual(slow, .unknown)
        // Stop: unknown at once, not after the time limit.
        let started = Date()
        let stopped = Task { await client.call("slow", arguments: [:], timeout: 60) }
        try await Task.sleep(nanoseconds: 200_000_000)
        stopped.cancel()
        let stoppedOutcome = await stopped.value
        XCTAssertEqual(stoppedOutcome, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(log.text.contains("called echo"))
        XCTAssertTrue(changed.text.contains("changed"))
        await client.close()
        let after = await client.call("echo", arguments: [:])
        if case .notSent = after {} else { XCTFail("a closed client sends nothing: \(after)") }
    }

    func testClientRefusesAVersionItDoesntSpeak() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("no python3 for the fake server") }
        let script = Self.fakeServer.replacingOccurrences(of: #"m["params"]["protocolVersion"]"#, with: #""1999-01-01""#)
        let client = MCPClient(transport: MCPStdioTransport(executable: python, arguments: ["-I", "-c", script],
                                                            environment: MCPStdioTransport.environment(adding: [:]), workingDirectory: nil))
        do {
            _ = try await client.start()
            XCTFail("started")
        } catch {
            XCTAssertEqual(error as? MCPError, .unsupportedVersion("1999-01-01"))
        }
    }

    func testServerEnvironmentIsMinimal() {
        let env = MCPStdioTransport.environment(adding: ["TOKEN": "t"], from: ["PATH": "/p", "HOME": "/h", "AWS_SECRET": "x"])
        XCTAssertEqual(env, ["PATH": "/p", "HOME": "/h", "TOKEN": "t"])
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var text: String { lock.withLock { lines.joined() } }
}

/// The real `apple-mail-mcp` (adr/0027), opt-in: MCP_LIVE_MAIL=<path to
/// server/apple-mail-mcp.js>. Read-only: lists tools and accounts.
final class MCPLiveMailTests: XCTestCase {
    func testAppleMailServer() async throws {
        guard let script = ProcessInfo.processInfo.environment["MCP_LIVE_MAIL"] else { throw XCTSkip("MCP_LIVE_MAIL not set") }
        let transport = MCPStdioTransport(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", script],
                                          environment: MCPStdioTransport.environment(adding: [:]),
                                          workingDirectory: (script as NSString).deletingLastPathComponent)
        let client = MCPClient(transport: transport)
        let info = try await client.start()
        print("server: \(info.name) \(info.version), MCP \(info.protocolVersion)")
        let tools = try await client.listTools()
        for tool in tools {
            print("tool \(tool.name): readOnlyHint=\(tool.readOnlyHint.map(String.init) ?? "-"), actions=\(tool.actionField?.values.count ?? 0)")
        }
        XCTAssertTrue(tools.contains { $0.name == "read" && $0.actionField?.name == "action" })
        let outcome = await client.call("read", arguments: ["action": "list_accounts"], timeout: 60)
        if case .result(let text, let isError) = outcome {
            print("list_accounts: isError=\(isError), \(text.count) characters")
        } else {
            XCTFail("\(outcome)")
        }
        await client.close()
    }
}
