import XCTest
@testable import LLMTrayCore

final class MemoryReflectionTests: XCTestCase {
    func testOpsPrettyPrintedOverLines() {
        // LFM2.5 2.6B's reply: one op over several lines, in a fence.
        let reply = "\n\n```json\n{\n  \"op\": \"add\",\n  \"topic\": \"work\",\n  \"text\": \"Бэкенд-разработчик на Go\",\n  \"quote\": \"я вообще-то бэкенд разработчик на Go\"\n}\n```"
        let ops = MemoryReflection.parseOperations(reply)
        XCTAssertEqual(ops?.count, 1)
        XCTAssertEqual(ops?.first?.text, "Бэкенд-разработчик на Go")
        // Two of them, a brace inside a string not counted.
        let two = "{\n \"op\": \"add\", \"text\": \"a {b}\", \"quote\": \"x\"\n}\n{\n \"op\": \"add\", \"text\": \"c\", \"quote\": \"y\"\n}"
        XCTAssertEqual(MemoryReflection.parseOperations(two)?.map(\.text), ["a {b}", "c"])
        // A brace in a single-quoted string is text too: nothing taken from it.
        XCTAssertNil(MemoryReflection.parseOperations("{\n  'error': '} {\"ops\":[]} {'\n}"))
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let chat = UUID()
    /// Learning shared: these tests are about the write itself; keeping it
    /// apart has its own below.
    let on = MemorySettings(enabled: true, shareLearned: true)

    func batch(_ texts: [String], before: String? = nil) -> MemoryBatch {
        MemoryBatch(id: 1, chat: chat, project: nil, created: t0,
                    messages: texts.enumerated().map { MemoryBatchMessage(seq: $0.offset + 1, date: t0, text: $0.element, before: before) })
    }

    // MARK: Replies

    func testOperationsFromAPlainOrWrappedReply() {
        let reply = """
        Sure! ```json
        {"ops": [
          {"op":"add","scope":"user","topic":"answer-length","kind":"preference","text":"Prefers short answers","quote":"keep it short"},
          {"op":"confirm","id":"m3","quote":"in Russian"},
          {"op":"update","id":"m4","quote":"x"},
          {"op":"add","kind":"fact","text":"No quote"},
          {"op":"jump","id":"m1","quote":"x"}
        ]}
        ```
        """
        let ops = MemoryReflection.parseOperations(reply)!
        XCTAssertEqual(ops.map(\.action), [.add, .confirm])
        XCTAssertEqual(ops[0].kind, .preference)
        XCTAssertEqual(ops[1].id, "m3")
        XCTAssertNil(MemoryReflection.parseOperations("no json here"))
        XCTAssertEqual(MemoryReflection.parseOperations(#"{"ops": []}"#), [])
        XCTAssertEqual(MemoryReflection.parseOperations("NONE"), [])
    }

    func testOperationsOnePerLineSurviveABrokenOne() {
        let reply = """
        {"op":"add","scope":"user","topic":"tone","kind":"preference","text":"Short answers","quote":"keep it short"}
        {"op":"add","kind":"fact","text":"Broken" "quote":
        {"op":"confirm","id":"m2","quote":"in Russian please"},
        """
        let ops = MemoryReflection.parseOperations(reply)!
        XCTAssertEqual(ops.map(\.action), [.add, .confirm])
        XCTAssertNil(MemoryReflection.parseOperations("{No durable facts found}"), "unreadable, not empty")
        XCTAssertNil(MemoryReflection.parseOperations("Nonetheless, nothing here."))
        XCTAssertEqual(MemoryReflection.parseOperations("none."), [])
        XCTAssertEqual(MemoryReflection.parseOperations(#"{"ops":[]}"# + "\n" + #"{"ops":[]}"#), [])
        let mixed = #"{"ops":[{"op":"confirm","id":"m1","quote":"short please"}]}"# + "\n" + #"{"op":"confirm","id":"m2","quote":"in russian"}"#
        XCTAssertEqual(MemoryReflection.parseOperations(mixed)?.compactMap(\.id), ["m1", "m2"])
    }

    func testOperationsAreCapped() {
        let one = #"{"op":"confirm","id":"m1","quote":"abc"}"#
        let reply = #"{"ops": ["# + Array(repeating: one, count: 30).joined(separator: ",") + "]}"
        XCTAssertEqual(MemoryReflection.parseOperations(reply)?.count, MemoryReflection.maxOperations)
    }

    func testVerdictsAndRelationsMustMatchTheCount() {
        XCTAssertEqual(MemoryReflection.parseVerdicts(#"{"verdicts":["yes","NO","maybe"]}"#, count: 3), [.yes, .no, .unclear])
        XCTAssertNil(MemoryReflection.parseVerdicts(#"{"verdicts":["yes"]}"#, count: 2))
        XCTAssertEqual(MemoryReflection.parseRelations(#"{"relations":["same","opposite","narrower","?"]}"#, count: 4),
                       [.same, .opposite, .narrower, .different])
        XCTAssertNil(MemoryReflection.parseRelations("{}", count: 1))
    }

    func testAnObservationWrittenAsAReplyIsDropped() {
        for text in ["I'd be happy to help with your creative requests.", "Конечно, я посмотрю. Что именно вас интересует?",
                     "Я буду рад помочь с вашими запросами.", "What would you like to change?"] {
            XCTAssertTrue(MemoryText.readsAsReply(text), text)
        }
        for text in ["Stay calm and go straight to the fix", "Сохранять спокойствие и сразу переходить к решению", "Be brief when they swear",
                     "When unclear, ask: What outcome do you want?", "Ignore small talk", "Surely be concise"] {
            XCTAssertFalse(MemoryText.readsAsReply(text), text)
        }
        let op = MemoryReflection.parseOperations(#"{"op":"add","kind":"observation","topic":"tone","observed":"Polite","text":"I'd be happy to help.","quote":"q"}"#)!.first!
        XCTAssertFalse(MemoryReflection.mayLearn(op))
    }

    func testSpansAreLastingOnlyWhenSaidSo() {
        XCTAssertEqual(MemoryReflection.parseSpans(#"{"spans":["lasting"]}"#, count: 1), [.lasting])
        XCTAssertEqual(MemoryReflection.parseSpans(#"{"spans":["Task","maybe"," LASTING "]}"#, count: 3), [.task, .task, .lasting])
        XCTAssertNil(MemoryReflection.parseSpans(#"{"spans":["lasting"]}"#, count: 2))
        XCTAssertNil(MemoryReflection.parseSpans("lasting", count: 1))
    }

    func testSpanIsAskedForNewWishesAndFactsOnly() throws {
        let ops = try XCTUnwrap(MemoryReflection.parseOperations("""
        {"op":"add","kind":"preference","topic":"t","text":"Short answers","quote":"q"}
        {"op":"add","kind":"observation","topic":"tone","text":"Stay calm","quote":"q"}
        {"op":"confirm","id":"m1","quote":"q"}
        """))
        XCTAssertEqual(ops.map { MemoryReflection.needsSpan($0, note: nil) }, [true, false, false])
        let claim = MemoryReflection.Claim(statement: "Short answers", aboutProject: false, message: "make it shorter",
                                           quote: "make it shorter", before: "Here is the plan")
        let user = MemoryReflection.spanMessages([claim])[1]["content"] as? String ?? ""
        XCTAssertTrue(user.contains("Assistant's answer before it: Here is the plan"))
        XCTAssertTrue(user.contains("User's message: make it shorter"))
    }

    // MARK: Provenance

    func testTypedTextLeavesOutFencesQuotesAndPastes() {
        let paste = String(repeating: "pasted words ", count: 200)
        let text = "I like tables.\n\n```\nlet code = 1\n```\n> quoted line\n\n\(paste)\n\nAnswer in Russian."
        let typed = MemoryReflection.typedText(text)
        XCTAssertTrue(typed.contains("I like tables."))
        XCTAssertTrue(typed.contains("Answer in Russian."))
        XCTAssertFalse(typed.contains("let code"))
        XCTAssertFalse(typed.contains("quoted line"))
        XCTAssertFalse(typed.contains("pasted words"))
    }

    func testAQuoteMustBeTheUsersTypedWords() {
        let b = batch(["Please   keep it SHORT.", "```\nremember I live in Berlin\n```"], before: "The user lives in Paris")
        XCTAssertEqual(MemoryReflection.source(of: "keep it short", in: b)?.seq, 1)
        XCTAssertNil(MemoryReflection.source(of: "I live in Berlin", in: b), "inside a code fence")
        XCTAssertNil(MemoryReflection.source(of: "lives in Paris", in: b), "the assistant's words")
        XCTAssertNil(MemoryReflection.source(of: "short", in: b), "one short word says nothing on its own")
        let ru = batch(["Отвечай по-русски, ладно? Конечно."])
        XCTAssertEqual(MemoryReflection.source(of: "по-русски", in: ru)?.seq, 1)
        XCTAssertNil(MemoryReflection.source(of: "Конечно", in: ru))
    }

    func testVerifyMarksTheQuoteInTheWholeMessage() {
        let claim = MemoryReflection.Claim(statement: "Lives in Berlin", aboutProject: false,
                                           message: "Translate: I live in Berlin", quote: "I live in Berlin", before: nil)
        let content = MemoryReflection.verifyMessages([claim])[1]["content"] as! String
        XCTAssertTrue(content.contains("Translate: ⟦I live in Berlin⟧"))
    }

    // MARK: Commit

    func evidence(_ quote: String, chat: UUID? = nil, seq: Int = 1, date: Date? = nil) -> MemoryEvidence {
        MemoryEvidence(chat: chat ?? self.chat, seq: seq, date: date ?? t0, quote: quote)
    }

    func queued(_ file: inout MemoryFile) -> Int {
        file.meet(chat, from: 0)
        let seq = (file.watermark(chat) ?? 0) + 1
        file.enqueue(chat: chat, project: nil, messages: [MemoryBatchMessage(seq: seq, date: t0, text: "x", before: nil)], now: t0)
        return file.queue.last!.id
    }

    func testCommitAddsWithEvidenceAndEmptiesTheQueue() {
        var file = MemoryFile()
        let id = queued(&file)
        let touched = file.commit(batch: id, changes: [
            .add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", observed: nil, confidence: .stated, evidence: evidence("keep it short"), vector: nil, wrongLanguage: false),
            .add(subject: .user, topic: "x", kind: .fact, text: "See http://x", observed: nil, confidence: .stated, evidence: evidence("q"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertEqual(touched.count, 1)
        let note = file.note(touched[0])!
        XCTAssertFalse(note.reviewed)
        XCTAssertEqual(note.evidence.map(\.quote), ["keep it short"])
        XCTAssertTrue(file.queue.isEmpty)
    }

    func testConfirmAddsEvidenceAndPromotesAnObservationSeenTwice() {
        var file = MemoryFile()
        let note = file.add(subject: .user, topic: "formatting", kind: .observation, text: "Likes tables", observed: "Asked for tables",
                            now: t0, reviewed: false, confidence: .inferred)!
        file.notes[0].evidence = [evidence("a table please")]
        let id = queued(&file)
        let otherChat = UUID()
        file.commit(batch: id, changes: [.confirm(id: note, evidence: evidence("table again", chat: otherChat, seq: 4,
                                                                              date: t0.addingTimeInterval(86_400 * 2)))],
                    since: file.generation, settings: on, liveProjects: [], now: t0.addingTimeInterval(86_400 * 2))
        let n = file.note(note)!
        XCTAssertEqual(n.kind, .preference)
        XCTAssertEqual(n.confidence, .inferred, "promoted, still a guess")
        XCTAssertEqual(n.evidence.count, 2)
    }

    func testUpdateAndSupersede() {
        var file = MemoryFile()
        let a = file.add(subject: .user, topic: "tone", kind: .preference, text: "Short answers", now: t0)!
        let b = file.add(subject: .user, topic: "tone", kind: .preference, text: "No emoji", now: t0, reviewed: false, confidence: .inferred)!
        let id = queued(&file)
        file.commit(batch: id, changes: [
            .update(id: a, text: "Short answers, in Russian", evidence: evidence("short, in Russian"), vector: nil, wrongLanguage: false),
            .supersede(id: b, text: "Emoji are fine", evidence: evidence("emoji are fine"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertEqual(file.note(a)?.text, "Short answers, in Russian")
        XCTAssertEqual(file.note(a)?.history.map(\.text), ["Short answers"])
        XCTAssertEqual(file.note(a)?.reviewed, false, "the model's words now")
        XCTAssertEqual(file.note(b)?.confidence, .stated)
        XCTAssertEqual(file.note(b)?.evidence.map(\.quote), ["emoji are fine"])
    }

    func testCommitLeavesPinnedAndRecentlyTouchedNotesAlone() {
        var file = MemoryFile()
        let pinned = file.add(subject: .user, topic: "tone", kind: .preference, text: "Pinned", now: t0)!
        file.setPinned(pinned, true, now: t0)
        let edited = file.add(subject: .user, topic: "tone", kind: .preference, text: "Edited", now: t0)!
        let id = queued(&file)
        let since = file.generation
        file.edit(edited, text: "Edited by the user meanwhile", now: t0)
        file.commit(batch: id, changes: [
            .update(id: pinned, text: "Changed", evidence: evidence("x"), vector: nil, wrongLanguage: false),
            .update(id: edited, text: "Model's version", evidence: evidence("y"), vector: nil, wrongLanguage: false),
            .forget(id: pinned, vector: nil),
        ], since: since, settings: on, liveProjects: [], now: t0)
        XCTAssertEqual(file.note(pinned)?.text, "Pinned")
        XCTAssertEqual(file.note(edited)?.text, "Edited by the user meanwhile")
    }

    func testCommitWritesNothingForAChatOptedOutMeanwhileOrATombstonedQuote() {
        var file = MemoryFile()
        let id = queued(&file)
        let forgotten = file.add(subject: .user, topic: "work", kind: .fact, text: "Old", now: t0)!
        file.notes[file.notes.count - 1].evidence = [evidence("i work at acme")]
        file.forget(forgotten)
        file.commit(batch: id, changes: [
            .add(subject: .user, topic: "work", kind: .fact, text: "Works at Acme", observed: nil, confidence: .stated, evidence: evidence("I  work at ACME"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertTrue(file.notes.isEmpty, "the same words don't teach a forgotten note again")

        var other = MemoryFile()
        let id2 = queued(&other)
        other.optedOut.insert(chat)
        other.commit(batch: id2, changes: [
            .add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", observed: nil, confidence: .stated, evidence: evidence("q"), vector: nil, wrongLanguage: false),
        ], since: other.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertTrue(other.notes.isEmpty)
        XCTAssertTrue(other.queue.isEmpty)
    }

    func testForgetByTheModelLeavesATombstoneWithTheVector() {
        var file = MemoryFile()
        let n = file.add(subject: .user, topic: "work", kind: .fact, text: "Works at Acme", now: t0, reviewed: false, confidence: .stated)!
        file.notes[0].evidence = [evidence("acme")]
        let id = queued(&file)
        file.commit(batch: id, changes: [.forget(id: n, vector: [1, 0])], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertNil(file.note(n))
        XCTAssertEqual(file.tombstones.last?.vector, [1, 0])
        file.dropTombstoneVectors()
        XCTAssertNil(file.tombstones.last?.vector)
        XCTAssertTrue(file.tombstones.last!.blocks(quote: "ACME"))
    }

    // MARK: Vectors

    func testVectorsRoundTripAndFollowTheText() throws {
        var file = MemoryFile()
        let id = file.add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", now: t0)!
        var vectors = MemoryVectors(model: "bge-m3@x")
        vectors.entries[id] = MemoryVectors.Entry(textHash: MemoryVectors.textHash("Be brief"), vector: [0.5, -1.25, 3])
        let decoded = try JSONDecoder().decode(MemoryVectors.self, from: JSONEncoder().encode(vectors))
        XCTAssertEqual(decoded.vector(for: file.note(id)!), [0.5, -1.25, 3])
        XCTAssertTrue(decoded.missing(file.notes).isEmpty)
        file.edit(id, text: "Be very brief", now: t0)
        XCTAssertEqual(decoded.missing(file.notes).map(\.id), [id])
        vectors.prune(to: [])
        XCTAssertTrue(vectors.entries.isEmpty)
        XCTAssertEqual(MemoryReflection.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(MemoryReflection.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(MemoryReflection.cosine([1], [1, 2]), 0)
    }

    // MARK: Review fixes

    func testObservedIsHeldToANotesRules() {
        let reply = #"{"ops":[{"op":"add","kind":"observation","text":"Likes tables","observed":"Opened https://x.com","quote":"show a table"}]}"#
        XCTAssertEqual(MemoryReflection.parseOperations(reply), [])
    }

    func testFencesCloseOnlyWithTheirOwnKind() {
        let text = "Before.\n\n````\n```\ncode inside\n```\nstill code\n````\nAfter fence."
        let typed = MemoryReflection.typedText(text)
        XCTAssertTrue(typed.contains("Before."))
        XCTAssertTrue(typed.contains("After fence."))
        XCTAssertFalse(typed.contains("code inside"))
        XCTAssertFalse(typed.contains("still code"))
    }

    func testALongMessageCountsOnlyItsShortParagraphs() {
        let paragraph = String(repeating: "word ", count: 150)   // 750 chars, under the paste length
        let text = (0..<5).map { _ in paragraph }.joined(separator: "\n\n") + "\n\nI prefer tabs."
        let typed = MemoryReflection.typedText(text)
        XCTAssertFalse(typed.contains("word word"))
        XCTAssertTrue(typed.contains("I prefer tabs."))
    }

    func testMergeKeepsOneWithBothsEvidence() {
        var file = MemoryFile()
        let older = file.add(subject: .user, topic: "tone", kind: .preference, text: "Short answers", now: t0, reviewed: false, confidence: .stated)!
        let newer = file.add(subject: .user, topic: "tone", kind: .preference, text: "Краткие ответы", now: t0.addingTimeInterval(60), reviewed: false, confidence: .stated)!
        file.notes[1].evidence = [evidence("коротко пожалуйста", seq: 7)]
        let id = queued(&file)
        file.commit(batch: id, changes: [
            .merge(keep: older, drop: newer, source: older, text: "Short answers, always", evidence: evidence("keep it short"),
                   vector: nil, wrongLanguage: false),
            .confirm(id: newer, evidence: evidence("short again", seq: 9)),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertNil(file.note(newer))
        XCTAssertEqual(file.note(older)?.text, "Short answers, always", "the verified update's text")
        XCTAssertEqual(Set(file.note(older)!.evidence.map(\.quote)), ["коротко пожалуйста", "keep it short", "short again"],
                       "a later change of the merged-away note goes to the one kept")
        XCTAssertTrue(file.tombstones.isEmpty, "a merge forgets nothing")
    }

    func testAMergeThatCantBeMadeIsTheUpdateAlone() {
        var file = MemoryFile()
        let mine = file.add(subject: .user, topic: "tone", kind: .preference, text: "Uses Python", now: t0, reviewed: false, confidence: .stated)!
        let pinned = file.add(subject: .user, topic: "tone", kind: .preference, text: "Python 3.12", now: t0)!
        file.setPinned(pinned, true, now: t0)
        let id = queued(&file)
        file.commit(batch: id, changes: [
            .merge(keep: mine, drop: pinned, source: mine, text: "Uses Python 3.12", evidence: evidence("python three twelve"),
                   vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertEqual(file.note(mine)?.text, "Uses Python 3.12")
        XCTAssertEqual(file.note(pinned)?.text, "Python 3.12")
    }

    func testTombstonedVectorsAreCheckedAtTheWrite() {
        var file = MemoryFile()
        let id = queued(&file)
        file.tombstones.append(MemoryTombstone(subject: .user, quoteHashes: [], vector: [1, 0], date: t0))
        file.commit(batch: id, changes: [
            .add(subject: .user, topic: "work", kind: .fact, text: "Works at Acme", observed: nil, confidence: .stated,
                 evidence: evidence("i work at acme"), vector: [0.99, 0.05], wrongLanguage: true),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertTrue(file.notes.isEmpty)
    }

    func testDeletedProjectsAndSettingsChangedMeanwhileWriteNothing() {
        let project = UUID()
        var file = MemoryFile()
        var id = queued(&file)
        file.commit(batch: id, changes: [
            .add(subject: .project(project), topic: "work", kind: .fact, text: "Uses OTA", observed: nil, confidence: .stated,
                 evidence: evidence("over the air"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertTrue(file.notes.isEmpty)
        id = queued(&file)
        file.commit(batch: id, changes: [
            .add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", observed: nil, confidence: .stated,
                 evidence: evidence("be brief"), vector: nil, wrongLanguage: true),
        ], since: file.generation, settings: MemorySettings(enabled: false), liveProjects: [], now: t0)
        XCTAssertTrue(file.notes.isEmpty)
        XCTAssertTrue(file.queue.isEmpty)
    }

    func testABatchMayChangeTheSameNoteTwice() {
        var file = MemoryFile()
        let n = file.add(subject: .user, topic: "tone", kind: .preference, text: "Short answers", now: t0, reviewed: false, confidence: .stated)!
        let id = queued(&file)
        file.commit(batch: id, changes: [
            .update(id: n, text: "Short answers, please", evidence: evidence("short please"), vector: nil, wrongLanguage: false),
            .supersede(id: n, text: "Detailed answers", evidence: evidence("actually go detailed"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: on, liveProjects: [], now: t0)
        XCTAssertEqual(file.note(n)?.text, "Detailed answers")
    }

    func testFailuresAreCountedApartFromDeferrals() {
        var file = MemoryFile()
        let id = queued(&file)
        file.deferBatch(id)
        file.deferBatch(id)
        XCTAssertEqual(file.failBatch(id), 1)
        XCTAssertEqual(file.queue.first?.attempts, 2)
    }

    func testRedirectsFollowChainsButNeverForget() {
        let e = MemoryEvidence(chat: chat, seq: 1, date: t0, quote: "two words")
        let map = ["b": "a", "a": "c"]
        XCTAssertEqual(MemoryChange.confirm(id: "b", evidence: e).redirected(map), .confirm(id: "c", evidence: e))
        XCTAssertEqual(MemoryChange.forget(id: "b", vector: nil).redirected(map), .forget(id: "b", vector: nil))
        XCTAssertEqual(MemoryChange.confirm(id: "x", evidence: e).redirected(["x": "y", "y": "x"]).isConfirm, true, "a loop ends")
    }
}

extension MemoryReflectionTests {
    func testKeptApartABatchWritesOnlyItsOwnPlace() {
        let x = UUID()
        let apart = MemorySettings(enabled: true)
        var file = MemoryFile()
        let global = file.add(subject: .user, topic: "tone", kind: .preference, text: "Detailed answers", now: t0)!
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: x, messages: [MemoryBatchMessage(seq: 1, date: t0, text: "x", before: nil)], now: t0)
        let id = file.queue.last!.id
        file.commit(batch: id, changes: [
            .supersede(id: global, text: "Terse answers", evidence: evidence("terse please"), vector: nil, wrongLanguage: false),
            .add(subject: .user, topic: "work", kind: .fact, text: "Leaks everywhere", observed: nil, confidence: .stated,
                 evidence: evidence("leaks everywhere"), vector: nil, wrongLanguage: false),
            .add(subject: .project(x), topic: "work", kind: .fact, text: "Uses OTA", observed: nil, confidence: .stated,
                 evidence: evidence("uses ota"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: apart, liveProjects: [x], now: t0)
        XCTAssertEqual(file.note(global)?.text, "Detailed answers", "a project's chat doesn't change what all chats see")
        XCTAssertEqual(file.notes.map(\.text).sorted(), ["Detailed answers", "Uses OTA"])
    }

    func testProjectChatsLearnNothingWithProjectNotesOffEvenShared() {
        let x = UUID()
        var settings = on
        settings.projectMemory = false
        var file = MemoryFile()
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: x, messages: [MemoryBatchMessage(seq: 1, date: t0, text: "x", before: nil)], now: t0)
        file.commit(batch: file.queue.last!.id, changes: [
            .add(subject: .user, topic: "work", kind: .fact, text: "From a project chat", observed: nil, confidence: .stated,
                 evidence: evidence("from a project"), vector: nil, wrongLanguage: false),
        ], since: file.generation, settings: settings, liveProjects: [x], now: t0)
        XCTAssertTrue(file.notes.isEmpty)
    }
}

private extension MemoryChange {
    var isConfirm: Bool { if case .confirm = self { return true } else { return false } }
}

extension MemoryReflectionTests {
    func testABatchIsReadByTheModelThatLastAnsweredInIt() {
        var file = MemoryFile()
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: nil, messages: [
            MemoryBatchMessage(seq: 1, date: t0, text: "a", before: nil, model: "gemma-4-26b"),
            MemoryBatchMessage(seq: 2, date: t0, text: "b", before: nil, model: "nemotron-coder"),
            MemoryBatchMessage(seq: 3, date: t0, text: "c", before: nil, model: nil),
        ], now: t0)
        XCTAssertEqual(file.queue.last?.model, "nemotron-coder")
    }

    func testModelCardLanguages() {
        let list = "---\nlicense: apache-2.0\nlanguage:\n- en\n- RU\ntags:\n- chat\n---\n# Model"
        XCTAssertEqual(ModelCardLanguages.parse(readme: list), ["en", "ru"])
        XCTAssertEqual(ModelCardLanguages.parse(readme: "---\nlanguage: [en, \"de\"]\n---"), ["en", "de"])
        XCTAssertEqual(ModelCardLanguages.parse(readme: "---\nlanguage: en\n---"), ["en"])
        XCTAssertNil(ModelCardLanguages.parse(readme: "# No front matter\nlanguage: en"))
        XCTAssertNil(ModelCardLanguages.parse(readme: "---\nlicense: mit\n---"))
        XCTAssertEqual(ModelCardLanguages.parse(readme: "---\nlanguage: en # supported\n...\nlanguage: fr"), ["en"])
        XCTAssertEqual(ModelCardLanguages.parse(readme: "---\nlanguage:\n- en\n\n# more\n- uk # Ukrainian\nlicense: mit\n---"), ["en", "uk"])
        XCTAssertTrue(ModelCardLanguages.covers(["en", "ru-RU"], "ru"))
        XCTAssertTrue(ModelCardLanguages.covers(["multilingual"], "uk"))
        XCTAssertFalse(ModelCardLanguages.covers(["en"], "ru"))
    }

    func testWhatMayBeLearned() {
        typealias Op = MemoryReflection.Operation
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .add, topic: "work", kind: .fact, text: "Quantizes LLMs with GPTQ", quote: "q")))
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .add, topic: "work", kind: .fact, text: "User asked what RDMA is", quote: "q")))
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .add, topic: "general", kind: .observation, text: "Is testing the AI's limits",
                                                    observed: "Asked for pictures on LSD", quote: "q")), "sensitive, and not about answering")
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .add, topic: "general", kind: .observation, text: "Curious about space", quote: "q")),
                       "an observation only about how to answer")
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .add, topic: "tone", kind: .observation, text: "Curt when a build breaks", quote: "q")))
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .update, id: "m1", text: "Has depression", quote: "q")))
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .update, id: "m1", topic: "general", text: "Short answers, in Russian", quote: "q")))
    }

    func testAddsAreCappedAskedForFirst() {
        XCTAssertEqual(MemoryReflection.keptAdds([.fact, .observation, .preference, .fact, .correction, .fact]), [0, 2, 3, 4])
        XCTAssertEqual(MemoryReflection.keptAdds([.fact, .fact, .fact]), [0, 1, 2])
        XCTAssertEqual(MemoryReflection.keptAdds([.observation]), [0])
    }

    func testOneOffPhrasingIsOnlyForFacts() {
        typealias Op = MemoryReflection.Operation
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .add, topic: "answer-length", kind: .preference, text: "Requests concise answers in Russian", quote: "q")))
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .add, topic: "answer-length", kind: .preference, text: "Просит краткие ответы", quote: "q")))
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .add, topic: "work", kind: .fact, text: "\nRequests an image of a cat", quote: "q")))
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .update, id: "m1", text: "Asks for tables in comparisons", quote: "q"), kind: .preference))
        XCTAssertFalse(MemoryReflection.mayLearn(Op(action: .update, id: "m1", text: "Asks about DRA", quote: "q"), kind: .fact))
        XCTAssertTrue(MemoryReflection.mayLearn(Op(action: .add, topic: "formatting", kind: .preference, text: "Tables for comparisons",
                                                   observed: "Asked for tables instead of lists", quote: "q")), "a preference's observed is dropped, not checked")
    }

    func testTrimmingEvidenceKeepsTheChatsItWasSeenIn() {
        let (a, b) = (UUID(), UUID())
        let t = Date()
        var evidence = [MemoryEvidence(chat: a, seq: 1, date: t, quote: "a")]
        for seq in 1...6 { evidence.append(MemoryEvidence(chat: b, seq: seq, date: t, quote: "b\(seq)")) }
        let kept = MemoryFile.trimmed(evidence)
        XCTAssertEqual(kept.count, MemoryFile.maxEvidence)
        XCTAssertEqual(Set(kept.map(\.chat)), [a, b])
        XCTAssertEqual(kept.last?.seq, 6)
    }

    func testAStrayBracketInALineIsRepaired() {
        let ops = MemoryReflection.parseOperations(#"{"op":"add","observed":"Swears","text":"Stay calm","quote":"damn it all","quote2":"argh this again"]}"#)
        XCTAssertEqual(ops?.count, 1)
        XCTAssertEqual(ops?.first?.also, "argh this again")
    }

    func testTriageLinesAndJSON() {
        typealias L = MemoryExtraction.Label
        XCTAssertEqual(MemoryExtraction.parseLabels("1: none\n2: about-me\n3: how-to-answer, manner", count: 3),
                       [[.none], [.aboutMe], [.howToAnswer, .manner]])
        XCTAssertEqual(MemoryExtraction.parseLabels("#2 - forget", count: 3), [[.none], [.forget], [.none]], "a message without a line is none")
        XCTAssertEqual(MemoryExtraction.parseLabels(#"{"labels": ["none", "about-me"]}"#, count: 2), [[.none], [.aboutMe]])
        XCTAssertNil(MemoryExtraction.parseLabels("I can't", count: 2))
        XCTAssertEqual(MemoryExtraction.parseLabels(#"{"message1": ["none"], "message2": ["about-me", "mood"]}"#, count: 3),
                       [[.none], [.aboutMe, .mood], [.none]], "fields per message; a missing one is none")
        XCTAssertEqual(MemoryExtraction.parseLabels("1: weird", count: 1), [[.none]])
    }

    func testTargetedPromptsCarryTheirNotesLanguageAndTypedText() {
        var file = MemoryFile()
        file.add(subject: .user, topic: "answer-length", kind: .preference, text: "Be brief", now: t0)
        let message = MemoryBatchMessage(seq: 1, date: t0, text: "Answer in Russian\n```\nI love Java\n```", before: "Earlier answer")
        let prompt = MemoryExtraction.instructionMessages([message], notes: file.notes, topics: ["tone"], language: "Russian", corrections: true)
        let system = prompt[0]["content"] as! String
        let user = prompt[1]["content"] as! String
        XCTAssertTrue(system.contains("written in Russian"))
        XCTAssertTrue(system.contains("One note per wish"))
        XCTAssertTrue(user.contains("m1 [preference, answer-length, user] Be brief"))
        XCTAssertTrue(user.contains("Before: Earlier answer\nUser: Answer in Russian"))
        XCTAssertFalse(user.contains("I love Java"), "code isn't the user's words")
        let fact = MemoryExtraction.factMessages([message], notes: [], topics: ["work"], language: "English", inProject: true)[0]["content"] as! String
        XCTAssertTrue(fact.contains("\"scope\": \"project\""))
        XCTAssertTrue(fact.contains("Never about health"))
    }

    func testTheExtractionAsksOnlyTheStepsItsMessagesNeed() async throws {
        let messages = ["what is RDMA?", "answer briefly please", "damn, broken again", "damn it, the linker again"]
            .enumerated().map { MemoryBatchMessage(seq: $0.offset + 1, date: t0, text: $0.element, before: nil) }
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: t0, messages: messages)
        var asked: [String] = []
        let ops = try await MemoryExtraction.reading(batch: batch, candidates: [], topics: ["tone"], language: "English",
                                                        kinds: Set(MemoryKind.allCases), inProject: false) { prompt, _, _ in
            let system = prompt[0]["content"] as! String
            asked.append(String(system.prefix(20)))
            if system.hasPrefix("You sort") { return "1: none\n2: how-to-answer\n3: none, manner\n4: manner" }
            if system.hasPrefix("You turn") {
                return #"{"op":"add","kind":"preference","topic":"answer-length","text":"Answer briefly","quote":"answer briefly please"}"#
                    + "\n" + #"{"op":"update","id":"m9","text":"Folded in","quote":"answer briefly please"}"#
            }
            if system.hasPrefix("You read") {
                return #"{"op":"add","observed":"Swears when it breaks","text":"Stay calm","quote":"damn, broken again","quote2":"the linker again"}"#
            }
            return "NONE"
        }?.operations
        XCTAssertEqual(asked.count, 3, "triage, instructions, manner -- no fact or forget step")
        XCTAssertEqual(ops?.map(\.action), [.add, .add])
        XCTAssertEqual(ops?.first?.kind, .preference)
        XCTAssertEqual(ops?.last?.kind, .observation)
        XCTAssertEqual(ops?.last?.topic, "tone")
    }

    func testAMannerNeedsTwoOfItsMessages() async throws {
        let messages = ["damn, broken again", "thanks, what is RDMA?", "ok"]
            .enumerated().map { MemoryBatchMessage(seq: $0.offset + 1, date: t0, text: $0.element, before: nil) }
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: t0, messages: messages)
        let ops = try await MemoryExtraction.reading(batch: batch, candidates: [], topics: [], language: "English",
                                                        kinds: Set(MemoryKind.allCases), inProject: false) { prompt, _, _ in
            let system = prompt[0]["content"] as! String
            if system.hasPrefix("You sort") { return "1: none, manner\n2: none\n3: none" }
            return #"{"op":"add","observed":"Swears","text":"Stay calm","quote":"damn, broken again","quote2":"what is RDMA"}"#
        }?.operations
        XCTAssertEqual(ops, [], "one message showing it: no step, no manner")
    }

    func testAMoodIsReadOnlyFromRecentMessages() async throws {
        let now = Date()
        let messages = [
            MemoryBatchMessage(seq: 1, date: now.addingTimeInterval(-86_400), text: "so tired of this", before: nil),
            MemoryBatchMessage(seq: 2, date: now, text: "damn, the linker failed again", before: nil),
        ]
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: now, messages: messages)
        var moodPrompt = ""
        let reading = try await MemoryExtraction.reading(batch: batch, candidates: [], topics: [], language: "English",
                                                         kinds: Set(MemoryKind.allCases), inProject: false,
                                                         moodSince: now.addingTimeInterval(-3 * 3600)) { prompt, _, _ in
            let system = prompt[0]["content"] as! String
            if system.hasPrefix("You sort") { return "1: none, mood\n2: none, mood" }
            if system.hasPrefix("From a user") {
                moodPrompt = prompt[1]["content"] as! String
                return #"{"observed":"Angry: the linker fails","text":"Brief, straight to the fix","quote":"the linker failed again"}"#
            }
            return "NONE"
        }
        XCTAssertFalse(moodPrompt.contains("so tired"), "a day old: not now")
        XCTAssertEqual(reading?.mood?.message.seq, 2)
        XCTAssertEqual(reading?.mood?.text, "Brief, straight to the fix")
        let off = try await MemoryExtraction.reading(batch: batch, candidates: [], topics: [], language: "English",
                                                     kinds: Set(MemoryKind.allCases), inProject: false) { prompt, _, _ in
            (prompt[0]["content"] as! String).hasPrefix("You sort") ? "1: mood\n2: mood" : #"{"observed":"x","text":"y","quote":"linker failed again"}"#
        }
        XCTAssertNil(off?.mood, "moods off")
    }

    func testTheSameMannerSeenAgainConfirmsItsNote() async throws {
        var file = MemoryFile()
        let id = file.add(subject: .general, topic: "tone", kind: .observation, text: "Stay calm", observed: "Swears when a build breaks",
                          now: t0, reviewed: false, confidence: .inferred)!
        let messages = ["damn, broken", "argh, damn it"].enumerated().map { MemoryBatchMessage(seq: $0.offset + 1, date: t0, text: $0.element, before: nil) }
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: t0, messages: messages)
        let ops = try await MemoryExtraction.reading(batch: batch, candidates: [], toneNotes: file.notes, topics: [], language: "English",
                                                     kinds: Set(MemoryKind.allCases), inProject: false) { prompt, _, _ in
            (prompt[0]["content"] as! String).hasPrefix("You sort") ? "1: manner\n2: manner"
                : #"{"op":"add","observed":"swears when a build breaks","text":"Go straight to the fix","quote":"damn, broken","quote2":"argh, damn it"}"#
        }?.operations
        XCTAssertEqual(ops?.map(\.action), [.confirm])
        XCTAssertEqual(ops?.first?.id, id)
    }

    func testAQuoteWithWordsLeftOutNeverDropsANegation() {
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: t0, messages: [
            MemoryBatchMessage(seq: 1, date: t0, text: "I do not live in Berlin", before: nil),
            MemoryBatchMessage(seq: 2, date: t0, text: "Отвечай мне, пожалуйста, коротко и по-русски, без воды", before: nil),
        ])
        XCTAssertNil(MemoryReflection.source(of: "I live in Berlin", in: batch))
        XCTAssertEqual(MemoryReflection.source(of: "Отвечай мне, пожалуйста, коротко, без воды", in: batch)?.seq, 2, "two words left out")
        XCTAssertNil(MemoryReflection.source(of: "Отвечай без воды", in: batch), "too many left out")
        let more = MemoryBatch(id: 2, chat: chat, project: nil, created: t0, messages: [
            MemoryBatchMessage(seq: 3, date: t0, text: "I don't live in Berlin", before: nil),
            MemoryBatchMessage(seq: 4, date: t0, text: "I work on compilers. I prefer very short answers", before: nil),
        ])
        XCTAssertNil(MemoryReflection.source(of: "I live in Berlin", in: more), "don't is a negation")
        let quoted = MemoryBatch(id: 3, chat: chat, project: nil, created: t0, messages: [
            MemoryBatchMessage(seq: 5, date: t0, text: "I do 'not' live in Berlin; I 'prefer' very short answers", before: nil)])
        XCTAssertNil(MemoryReflection.source(of: "I live in Berlin", in: quoted), "'not' is not")
        XCTAssertEqual(MemoryReflection.source(of: "I prefer short answers", in: quoted)?.seq, 5)
        XCTAssertEqual(MemoryReflection.source(of: "I prefer short answers", in: more)?.seq, 4, "the second I")
        XCTAssertNil(MemoryReflection.parseOperations(#"{"op":"add","text":"a [b] c","quote":"x y"]}"#)?.first, "a line with [ isn't repaired")
    }

    func testTheSortersGateReadsYesOrNoPerMessage() async throws {
        let messages = ["how do I set up nginx?", "too vague, be concrete"].enumerated().map {
            MemoryBatchMessage(seq: $0.offset + 1, date: t0, text: $0.element, before: nil)
        }
        let batch = MemoryBatch(id: 1, chat: chat, project: nil, created: t0, messages: messages)
        var shape: ReplyShape?
        let yes = try await MemoryExtraction.gate(batch) { _, _, s in
            shape = s
            return #"{"message1": ["no"], "message2": ["yes"]}"#
        }
        XCTAssertEqual(yes, true)
        XCTAssertEqual(shape, .labels(count: 2, choices: ["yes", "no"]))
        let no = try await MemoryExtraction.gate(batch) { _, _, _ in #"{"message1": ["no"], "message2": "no"}"# }
        XCTAssertEqual(no, false)
        let unreadable = try await MemoryExtraction.gate(batch) { _, _, _ in "sure" }
        XCTAssertNil(unreadable)
        let partial = try await MemoryExtraction.gate(batch) { _, _, _ in #"{"message1": ["no"]}"# }
        XCTAssertNil(partial, "a message unanswered isn't a no")
        let odd = try await MemoryExtraction.gate(batch) { _, _, _ in #"{"message1": ["no"], "message2": ["maybe"]}"# }
        XCTAssertNil(odd)
        let mixed = try await MemoryExtraction.gate(batch) { _, _, _ in #"{"message1": ["no", 42], "message2": ["no\n"]}"# }
        XCTAssertNil(mixed, "a number in it isn't an answer")
    }
}
