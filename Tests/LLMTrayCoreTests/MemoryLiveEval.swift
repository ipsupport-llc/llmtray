import XCTest
@testable import LLMTrayCore

/// Memory's reflection against a real model (adr/0024's reflection eval):
/// skipped unless MEMORY_EVAL_PORT is set. It mirrors MemoryReflector's
/// pass (candidates by meaning, reflect, provenance, verify, reconcile,
/// commit) on fixture chats and prints the notes it ends with. Run it on the
/// user's Mac only on their say-so:
///
///   MEMORY_EVAL_PORT=8791 MEMORY_EVAL_MODEL=<model folder> MEMORY_EVAL_SET=1|2|3|4|5 \
///   MEMORY_EVAL_STATE=/tmp/memory-eval.json swift test --filter MemoryLiveEval
///
/// MEMORY_EVAL_MODEL=apple-system (no port): Apple's on-device model, in-process.
///
/// with an mlx_lm.server of that model on the port. The state file carries
/// the notes from one set (one model) to the next (another model). It's the
/// pass's model-facing part; the app's extra paths (merges of updates, a
/// batch's repeated adds, failure counting) are left out, so it may show a
/// note more than the app would keep.
final class MemoryLiveEval: XCTestCase {
    struct Chat {
        var project: UUID?
        var messages: [(before: String?, text: String)]
        /// How long ago it was said (a mood counts only for a few hours).
        var hoursAgo: Double = 0
    }

    static let projectX = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    static let sets: [Int: [Chat]] = [
        1: [
            Chat(project: nil, messages: [
                (nil, "Привет! Отвечай мне, пожалуйста, коротко и по-русски, без воды."),
                ("Конечно! Чем помочь?", "Я делаю умную колонку на ESP32-S3, прошивка обновляется по воздуху."),
                ("Звучит интересно.", "Переведи на английский: «Я живу в Берлине и работаю врачом»."),
                ("I live in Berlin and work as a doctor.", "блин, опять сборка упала, черт"),
                ("Что пишет лог?", "да черт с ним, опять этот проклятый линкер падает"),
            ]),
            Chat(project: projectX, messages: [
                (nil, "For this project use PlatformIO, not the Arduino IDE."),
                ("Got it.", "Imagine I were a lawyer - how would you explain OTA updates to me?"),
                ("Like a contract amendment...", "My colleague Anna prefers tabs over spaces, by the way."),
                ("Noted.", "damn, the OTA broke again, wtf"),
            ]),
            Chat(project: nil, messages: [
                ("Sounds like you might be a teacher?", "yes"),
                ("Sure.", "```\n# config\nI love Java and I live in Paris\n```\nWhat does this config do?"),
                ("It's a comment.", "Please never invent chart data when you don't have the numbers."),
                ("Understood.", "I'm so tired today, long night."),
            ]),
        ],
        2: [
            Chat(project: nil, messages: [
                (nil, "Keep your answers short, please."),
                ("Sure.", "My speaker project runs on an ESP32-S3 with over-the-air updates."),
                ("Nice.", "argh, this damn build failed again"),
            ]),
            Chat(project: nil, messages: [
                (nil, "Не выдумывай данные для графиков, если цифр нет."),
                ("Хорошо.", "Я по жизни программист на Swift, пишу под macOS."),
            ]),
        ],
        // One-off questions, creative and test prompts, a sensitive topic:
        // nothing. A fact said in two chats is sent; said in one, it waits.
        // Expected: quantization fact (2 chats, sent), "concrete answers
        // with versions" and "tables for comparisons" (preferences, sent);
        // Kubernetes/RDMA questions, the images, LSD/alcohol, depression: none.
        3: [
            Chat(project: nil, messages: [
                (nil, "что такое RDMA?"),
                ("RDMA — это прямой доступ к памяти другого узла...", "нарисуй океаническую планету в космосе"),
                ("Готово, вот картинка.", "а теперь представь то же самое под ЛСД"),
                ("Вот вариант в психоделическом стиле.", "а теперь под алкоголем"),
                ("Вот размытый вариант.", "я вообще занимаюсь квантизацией LLM, сейчас гоняю GPTQ на Nemotron"),
            ]),
            Chat(project: nil, messages: [
                (nil, "какая версия Kubernetes поддерживает DRA?"),
                ("DRA появился в одной из версий...", "блин, опять расплывчато. отвечай конкретно, с номерами версий"),
                ("Kubernetes 1.32 в beta, 1.34 GA.", "ок. кстати, мой GPTQ-пайплайн квантизации сейчас на 8 GPU"),
            ]),
            Chat(project: nil, messages: [
                (nil, "у меня депрессия последние недели, ничего не хочется"),
                ("Мне жаль это слышать...", "сравни H100 и B200"),
                ("Вот сравнение списком...", "для сравнений мне больше нравятся таблицы, делай таблицей"),
            ]),
        ],
        // Mood: a day-old tired chat gives none; a fresh angry one does;
        // depression never. Expected mood: angry at the linker, answer briefly.
        4: [
            Chat(project: nil, messages: [
                (nil, "я так устал от этого проекта, сил нет"),
                ("Понимаю. Чем помочь?", "ладно, давай посмотрим конфиг"),
            ], hoursAgo: 30),
            Chat(project: nil, messages: [
                (nil, "у меня депрессия, всё бесит"),
                ("Сочувствую.", "что за фигня, опять линкер падает, третий раз за час!"),
                ("Давай разберёмся: что в логе?", "просто скажи, что делать, без длинных объяснений"),
            ]),
        ],
        // Nothing to learn: questions and tasks only. With Apple as the
        // sorter, every batch should be done without the reading model.
        5: [
            Chat(project: nil, messages: [
                (nil, "как поднять nginx reverse proxy для двух доменов?"),
                ("Вот конфиг...", "а с https через certbot?"),
                ("Добавь блок...", "спасибо, а как проверить, что сертификат продлевается?"),
            ]),
            Chat(project: nil, messages: [
                (nil, "Translate to German: the meeting is moved to Friday."),
                ("Das Meeting wird auf Freitag verschoben.", "and to French?"),
            ]),
            Chat(project: nil, messages: [
                (nil, "напиши функцию на python, которая считает медиану списка"),
                ("def median(xs): ...", "добавь тесты"),
                ("Вот тесты...", "ок, работает"),
            ]),
            // A task's own details and asks aren't lasting (a real queue's batch).
            Chat(project: nil, messages: [
                (nil, "hi, please take a look on a contract is there is anything wrong with it?"),
                ("Since I don't know if you are the Buyer or the Seller...", "okay, we are buyer in this contract please propose changes I need to ask about"),
                ("Here are the changes to ask for...", "make it shorter, just a list"),
            ]),
        ],
    ]

    var port = 0
    var modelPath = ""
    var thinking: [String: Any] = [:]

    func testLiveEval() async throws {
        let env = ProcessInfo.processInfo.environment
        let apple = env["MEMORY_EVAL_MODEL"] == AppleSystemModel.id
        guard let portText = env["MEMORY_EVAL_PORT"] ?? (apple ? "0" : nil), let port = Int(portText) else {
            throw XCTSkip("MEMORY_EVAL_PORT not set (or MEMORY_EVAL_MODEL=\(AppleSystemModel.id))")
        }
        self.port = port
        // Line by line, so a redirected run's log has it all.
        setvbuf(stdout, nil, _IOLBF, 0)
        defer { fflush(stdout) }
        modelPath = env["MEMORY_EVAL_MODEL"] ?? ""
        let template = (try? String(contentsOfFile: modelPath + "/chat_template.jinja", encoding: .utf8)) ?? ""
        thinking = Thinking.requestFields(style: Thinking.style(chatTemplate: template), effort: .off)
        let set = Int(env["MEMORY_EVAL_SET"] ?? "1") ?? 1
        let statePath = env["MEMORY_EVAL_STATE"] ?? NSTemporaryDirectory() + "memory-eval.json"
        let vectorsPath = statePath + ".vectors"

        var file = (try? JSONDecoder().decode(MemoryFile.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))) ?? MemoryFile()
        var settings = MemorySettings(enabled: true)
        settings.shareLearned = env["MEMORY_EVAL_SHARE"] == "1"
        let runner = try makeRunner()
        try await runner.start()
        defer { runner.stop() }
        let entryModel = "bge-m3"
        var vectors = (try? JSONDecoder().decode(MemoryVectors.self, from: Data(contentsOf: URL(fileURLWithPath: vectorsPath))))
            ?? MemoryVectors(model: entryModel)

        // MEMORY_EVAL_REAL=<notes.json>: its queued batches (a copy of the
        // user's), read as the app reads them -- to see why they fail.
        if let real = env["MEMORY_EVAL_REAL"],
           let copy = try? JSONDecoder.iso.decode(MemoryFile.self, from: Data(contentsOf: URL(fileURLWithPath: real))) {
            file.queue = Array(copy.queue.prefix(Int(env["MEMORY_EVAL_LIMIT"] ?? "3") ?? 3))
            file.notes = copy.notes
        }
        for chat in env["MEMORY_EVAL_REAL"] == nil ? (Self.sets[set] ?? []) : [] {
            let id = UUID()
            file.meet(id, from: 0)
            let messages = chat.messages.enumerated().map {
                MemoryBatchMessage(seq: $0.offset + 1, date: Date().addingTimeInterval(-chat.hoursAgo * 3600), text: $0.element.text,
                                   before: $0.element.before, model: modelPath)
            }
            file.enqueue(chat: id, project: chat.project, messages: messages, now: Date())
        }
        while let batch = file.queue.first {
            print("\n=== batch \(batch.id) (\(batch.project == nil ? "outside projects" : "project X"), \(batch.messages.count) messages)")
            try await pass(batch, file: &file, vectors: &vectors, settings: settings, runner: runner)
        }
        try JSONEncoder().encode(file).write(to: URL(fileURLWithPath: statePath))
        try JSONEncoder().encode(vectors).write(to: URL(fileURLWithPath: vectorsPath))

        print("\n=== notes after set \(set) (\((modelPath as NSString).lastPathComponent))")
        if let mood = file.mood { print("- [mood] \(mood.observed) → \(mood.text) — evidence: \"\(mood.quote)\"") }
        for note in file.notes {
            let scope: String
            switch note.subject {
            case .user: scope = "all"
            case .general: scope = "outside"
            case .project: scope = "project X"
            }
            print("- [\(note.kind.rawValue), \(note.topic), \(scope), \(note.confidence.rawValue)\(settings.isEstablished(note) ? "" : ", waits")] \(note.text)"
                + (note.observed.map { " (observed: \($0))" } ?? "")
                + " — evidence: " + note.evidence.map { "\"\($0.quote)\"" }.joined(separator: "; ")
                + (note.wrongLanguage == true ? " [wrong language]" : ""))
        }
    }

    // MARK: The pass, as MemoryReflector runs it

    func pass(_ batch: MemoryBatch, file: inout MemoryFile, vectors: inout MemoryVectors, settings: MemorySettings,
              runner: EmbedRunner) async throws {
        let since = file.generation
        let missing = vectors.missing(file.notes)
        for (note, v) in zip(missing, try await embed(missing.map(\.text), .document, runner)) {
            vectors.entries[note.id] = MemoryVectors.Entry(textHash: MemoryVectors.textHash(note.text), vector: v)
        }
        let messageVectors = try await embed(batch.messages.map { String(MemoryReflection.typedText($0.text).prefix(2000)) }, .query, runner)
        let fixed = settings.shareLearned ? nil : settings.learnedSubject(project: batch.project)
        let project = settings.projectMemory ? batch.project : nil
        let touchable = file.notes.filter { note in
            !note.pinned && (fixed.map { note.subject == $0 } ?? true) && settings.allows(note, project: batch.project, candidates: true)
        }
        let ranked = touchable.map { note -> (MemoryNote, Float) in
            let v = vectors.vector(for: note)
            return (note, v.map { nv in messageVectors.map { MemoryReflection.cosine(nv, $0) }.max() ?? 0 } ?? 0)
        }.filter { $0.1 >= 0.35 }.sorted { $0.1 > $1.1 }
        let candidates = Array(ranked.prefix(12).map(\.0))
        // What the model may name: the candidates, and every manner note (MemoryExtraction's toneNotes).
        let shown = Dictionary((candidates + touchable.filter { $0.kind == .observation && $0.topic == "tone" }).map { ($0.id, $0) },
                               uniquingKeysWith: { a, _ in a })
        let topics = Array(Set(MemoryTopics.builtIn + file.notes.map(\.topic))).sorted()

        let debug = ProcessInfo.processInfo.environment["MEMORY_EVAL_DEBUG"] == "1"
        // MEMORY_EVAL_SORTER=apple-system: Apple's model sorts first (adr/0025).
        if ProcessInfo.processInfo.environment["MEMORY_EVAL_SORTER"] == AppleSystemModel.id {
            let anything = try await MemoryExtraction.gate(batch) { messages, maxTokens, shape in
                try await AppleSystemModel.complete(messages: messages, maxTokens: maxTokens, temperature: 0.2, shape: shape)
            }
            print("  ⇢ Apple: anything? \(anything.map(String.init(describing:)) ?? "unreadable")")
            if anything == false {
                file.dropBatch(batch.id)
                print("commit: nothing to read (sorted by Apple)")
                return
            }
        }
        guard let reading = try await MemoryExtraction.reading(
            batch: batch, candidates: candidates, toneNotes: touchable.filter { $0.kind == .observation && $0.topic == "tone" },
            topics: topics, language: "Russian", kinds: settings.kinds,
            inProject: settings.shareLearned && project != nil,
            moodSince: Date().addingTimeInterval(-Double(settings.moodHours) * 3600),
            ask: { messages, maxTokens, shape in
                let reply = try await self.ask(messages, maxTokens, shape)
                if debug { print("  [\((messages[0]["content"] as? String ?? "").prefix(40))…] → \(reply.prefix(500).replacingOccurrences(of: "\n", with: "⏎"))") }
                return reply
            }) else {
            print("!! unreadable reply")
            file.failBatch(batch.id)
            file.dropBatch(batch.id)
            return
        }
        let ops = reading.operations
        if let mood = reading.mood {
            print("  ☁ mood: \(mood.observed) → \(mood.text) ← \"\(mood.quote)\"")
            file.setMood(MemoryMood(observed: mood.observed, text: mood.text, date: mood.message.date, chat: batch.chat, quote: mood.quote))
        }
        print("reflect: \(ops.count) op(s)")
        struct Pending { var op: MemoryReflection.Operation; var message: MemoryBatchMessage; var subject: MemorySubject; var claim: MemoryReflection.Claim; var spanned: Bool }
        var pending: [Pending] = []
        for op in ops {
            let label = "\(op.action.rawValue) \(op.id ?? "") \(op.text ?? "") ← \"\(op.quote)\""
            guard let message = MemoryReflection.source(of: op.quote, in: batch) else { print("  ✗ provenance: \(label)"); continue }
            let note = op.id.flatMap { shown[$0] }
            var subject: MemorySubject
            var statement: String
            switch op.action {
            case .add:
                guard let kind = op.kind, settings.kinds.contains(kind), let text = op.text, MemoryReflection.mayLearn(op) else {
                    print("  ✗ rules: \(label)"); continue
                }
                subject = fixed ?? (op.scope == "project" ? project.map(MemorySubject.project) ?? .user : .user)
                statement = kind == .observation ? (op.observed ?? text) : text
            case .confirm, .forget:
                guard let note else { print("  ✗ unknown id: \(label)"); continue }
                subject = note.subject
                statement = op.action == .confirm ? MemoryReflection.confirmStatement(note) : "The user asks to forget this, or says it is no longer true: \(note.text)"
            case .update, .supersede:
                guard let note, let text = op.text, MemoryReflection.mayLearn(op, kind: note.kind) else { print("  ✗ id/rules: \(label)"); continue }
                subject = note.subject
                statement = text
            }
            print("  · \(label)")
            pending.append(Pending(op: op, message: message, subject: subject,
                                   claim: .init(statement: statement, aboutProject: { if case .project = subject { return true } else { return false } }(),
                                                message: message.text, quote: op.quote, before: message.before,
                                                isObservation: MemoryReflection.isShown(op, note: note)),
                                   spanned: MemoryReflection.needsSpan(op, note: note)))
        }
        if !pending.isEmpty {
            let reply = try await ask(MemoryReflection.verifyMessages(pending.map(\.claim)), 40 + 12 * pending.count,
                                      MemoryReflection.verdictShape(pending.count))
            guard let verdicts = MemoryReflection.parseVerdicts(reply, count: pending.count) else {
                print("!! unreadable verify reply: \(reply.prefix(300))")
                file.dropBatch(batch.id)
                return
            }
            for (p, v) in zip(pending, verdicts) where v != .yes { print("  ✗ verify \(v.rawValue): \(p.claim.statement)") }
            pending = zip(pending, verdicts).filter { $0.1 == .yes }.map(\.0)
        }
        var tasks = Set<Int>()
        for i in pending.indices where pending[i].spanned {
            let reply = try await ask(MemoryReflection.spanMessages([pending[i].claim]), 40, MemoryReflection.spanShape(1))
            if ProcessInfo.processInfo.environment["MEMORY_EVAL_DEBUG"] == "1" { print("  [span] → \(reply.prefix(200))") }
            guard let span = MemoryReflection.parseSpans(reply, count: 1)?.first else {
                print("!! unreadable span reply: \(reply.prefix(300))")
                file.dropBatch(batch.id)
                return
            }
            if span == .task { tasks.insert(i); print("  ✗ task only: \(pending[i].claim.statement)") }
        }
        pending = pending.indices.filter { !tasks.contains($0) }.map { pending[$0] }
        let adds = pending.indices.filter { pending[$0].op.action == .add }
        let kept = Set(MemoryReflection.keptAdds(adds.map { pending[$0].op.kind }).map { adds[$0] })
        for i in adds where !kept.contains(i) { print("  ✗ over the cap: \(pending[i].op.text ?? "")") }
        pending = pending.indices.filter { pending[$0].op.action != .add || kept.contains($0) }.map { pending[$0] }
        let newTexts = Array(Set(pending.compactMap { [.add, .update, .supersede].contains($0.op.action) ? $0.op.text : nil }))
        let newVectors = Dictionary(zip(newTexts, try await embed(newTexts, .document, runner)), uniquingKeysWith: { a, _ in a })
        var pairs: [(new: String, old: String)] = []
        var owners: [(Int, MemoryNote?)] = []
        var similarities: [Float?] = []
        for (i, p) in pending.enumerated() where [.add, .update, .supersede].contains(p.op.action) {
            guard let text = p.op.text, let v = newVectors[text] else { continue }
            let close = file.notes.filter { note in
                guard note.id != p.op.id else { return false }
                if p.op.action == .add { return note.subject == p.subject || settings.allows(note, project: batch.project, candidates: true) }
                return note.subject == p.subject && !note.pinned
            }.compactMap { n in vectors.vector(for: n).map { (n, MemoryReflection.cosine($0, v)) } }
                .filter { $0.1 >= 0.6 }.sorted { $0.1 > $1.1 }.prefix(3)
            for (n, sim) in close {
                pairs.append((text, n.text))
                owners.append((i, n))
                similarities.append(sim)
                print(String(format: "  ~ %.2f \"%@\" vs \"%@\"", sim, text, n.text))
            }
            if p.op.action == .update, let own = p.op.id.flatMap({ shown[$0] }) {
                pairs.append((text, own.text))
                owners.append((i, nil))
                similarities.append(nil)
                print("  ~ own \"\(text)\" vs \"\(own.text)\"")
            }
        }
        var relations: [MemoryReflection.Relation] = []
        if !pairs.isEmpty {
            let reply = try await ask(MemoryReflection.classifyMessages(pairs), 40 + 12 * pairs.count,
                                      MemoryReflection.relationShape(pairs.count))
            relations = MemoryReflection.settled(MemoryReflection.parseRelations(reply, count: pairs.count)
                                                     ?? Array(repeating: .different, count: pairs.count), similarities: similarities)
            print("  classify: \(relations.map(\.rawValue))")
        }
        var changes: [MemoryChange] = []
        for (i, p) in pending.enumerated() {
            let evidence = MemoryEvidence(chat: batch.chat, seq: p.message.seq, date: p.message.date, quote: p.op.quote)
            let mine = owners.indices.filter { owners[$0].0 == i }
            let text = p.op.text ?? ""
            switch p.op.action {
            case .add:
                if let s = mine.first(where: { relations[$0] == .same || relations[$0] == .broader }), let n = owners[s].1 {
                    changes.append(.confirm(id: n.id, evidence: evidence))
                } else if let o = mine.first(where: { relations[$0] == .opposite }), let n = owners[o].1, !n.pinned, n.subject == p.subject {
                    changes.append(.supersede(id: n.id, text: text, evidence: evidence, vector: newVectors[text], wrongLanguage: false))
                } else {
                    changes.append(.add(subject: p.subject, topic: MemoryTopics.learned(p.op.topic), kind: p.op.kind!, text: text,
                                        observed: p.op.kind == .observation ? p.op.observed : nil,
                                        confidence: p.op.kind == .observation ? .inferred : .stated, evidence: evidence,
                                        vector: newVectors[text], wrongLanguage: false))
                }
            case .confirm: changes.append(.confirm(id: p.op.id!, evidence: evidence))
            case .update:
                if mine.contains(where: { owners[$0].1 == nil && relations[$0] == .broader }) {
                    print("  ↺ update says less than its note: confirm")
                    changes.append(.confirm(id: p.op.id!, evidence: evidence))
                } else {
                    changes.append(.update(id: p.op.id!, text: text, evidence: evidence, vector: newVectors[text], wrongLanguage: false))
                }
            case .supersede: changes.append(.supersede(id: p.op.id!, text: text, evidence: evidence, vector: newVectors[text], wrongLanguage: false))
            case .forget: changes.append(.forget(id: p.op.id!, vector: nil))
            }
        }
        let touched = file.commit(batch: batch.id, changes: changes, since: since, settings: settings,
                                  liveProjects: [Self.projectX], now: Date())
        for id in touched {
            guard let note = file.note(id), let v = newVectors[note.text] else { continue }
            vectors.entries[id] = MemoryVectors.Entry(textHash: MemoryVectors.textHash(note.text), vector: v)
        }
        print("commit: \(changes.count) change(s), \(touched.count) note(s) touched")
    }

    // MARK: Model and embedder

    func ask(_ messages: [[String: Any]], _ maxTokens: Int, _ shape: ReplyShape? = nil) async throws -> String {
        // Apple's on-device model, in-process (adr/0025): no server.
        if modelPath == AppleSystemModel.id {
            return try await AppleSystemModel.complete(messages: messages, maxTokens: maxTokens, temperature: 0.2, shape: shape)
        }
        var body: [String: Any] = ["model": "default_model", "messages": messages, "max_tokens": maxTokens, "temperature": 0.2]
        body.merge(thinking) { $1 }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return message?["content"] as? String ?? String(decoding: data, as: UTF8.self)
    }

    func makeRunner() throws -> EmbedRunner {
        let support = NSHomeDirectory() + "/Library/Application Support/LLMTray"
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return EmbedRunner(configuration: EmbedRunner.Configuration(
            executable: support + "/mlx_server_venv/bin/python3",
            arguments: [repo + "/runtime/llmtray_embed_runner.py", "--registry", repo + "/runtime/embedders.json",
                        "--entry", "bge-m3", "--model-dir", support + "/embed_models/bge-m3", "--parent", String(getpid())],
            environment: ["PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false"]))
    }

    func embed(_ texts: [String], _ kind: EmbedRunnerMessage.Kind, _ runner: EmbedRunner) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var out: [[Float]] = []
        for range in runner.documentBatches(texts) {
            let r = try await runner.embed(Array(texts[range]), kind: kind, timeout: 120)
            out += (0..<r.count).map(r.floats)
        }
        return out
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
