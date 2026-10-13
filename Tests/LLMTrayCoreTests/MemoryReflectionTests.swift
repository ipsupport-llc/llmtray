import XCTest
@testable import LLMTrayCore

final class MemoryReflectionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let chat = UUID()
    let on = MemorySettings(enabled: true)

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
        XCTAssertNil(MemoryReflection.source(of: "ke", in: b), "too short to mean anything")
    }

    func testVerifyMarksTheQuoteInTheWholeMessage() {
        let claim = MemoryReflection.Claim(statement: "Lives in Berlin", aboutProject: false,
                                           message: "Translate: I live in Berlin", quote: "I live in Berlin", before: nil)
        let content = MemoryReflection.verifyMessages([claim])[1]["content"] as! String
        XCTAssertTrue(content.contains("Translate: ⟦I live in Berlin⟧"))
    }

    func testReflectPromptCarriesTheLanguageCandidatesAndContext() {
        var file = MemoryFile()
        file.add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", now: t0)
        let messages = MemoryReflection.reflectMessages(batch: batch(["hello"], before: "Earlier answer"), candidates: file.notes,
                                                        topics: ["tone"], language: "Russian", kinds: [.fact, .preference],
                                                        inProject: false)
        let system = messages[0]["content"] as! String
        let user = messages[1]["content"] as! String
        XCTAssertTrue(system.contains("written in Russian"))
        XCTAssertTrue(system.contains("one of fact, preference:"))
        XCTAssertTrue(system.contains("scope is always \"user\""))
        XCTAssertTrue(user.contains("m1 [preference, tone, user] Be brief"))
        XCTAssertTrue(user.contains("Before: Earlier answer\nUser: hello"))
    }

    // MARK: Commit

    func evidence(_ quote: String, chat: UUID? = nil, seq: Int = 1, date: Date? = nil) -> MemoryEvidence {
        MemoryEvidence(chat: chat ?? self.chat, seq: seq, date: date ?? t0, quote: quote)
    }

    func queued(_ file: inout MemoryFile) -> Int {
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: nil, messages: [MemoryBatchMessage(seq: 1, date: t0, text: "x", before: nil)], now: t0)
        return file.queue.last!.id
    }

    func testCommitAddsWithEvidenceAndEmptiesTheQueue() {
        var file = MemoryFile()
        let id = queued(&file)
        let touched = file.commit(batch: id, changes: [
            .add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", observed: nil, confidence: .stated, evidence: evidence("keep it short")),
            .add(subject: .user, topic: "x", kind: .fact, text: "See http://x", observed: nil, confidence: .stated, evidence: evidence("q")),
        ], since: file.generation, settings: on, now: t0)
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
                    since: file.generation, settings: on, now: t0.addingTimeInterval(86_400 * 2))
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
            .update(id: a, text: "Short answers, in Russian", evidence: evidence("short, in Russian")),
            .supersede(id: b, text: "Emoji are fine", evidence: evidence("emoji are fine")),
        ], since: file.generation, settings: on, now: t0)
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
            .update(id: pinned, text: "Changed", evidence: evidence("x")),
            .update(id: edited, text: "Model's version", evidence: evidence("y")),
            .forget(id: pinned, vector: nil),
        ], since: since, settings: on, now: t0)
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
            .add(subject: .user, topic: "work", kind: .fact, text: "Works at Acme", observed: nil, confidence: .stated, evidence: evidence("I  work at ACME")),
        ], since: file.generation, settings: on, now: t0)
        XCTAssertTrue(file.notes.isEmpty, "the same words don't teach a forgotten note again")

        var other = MemoryFile()
        let id2 = queued(&other)
        other.optedOut.insert(chat)
        other.commit(batch: id2, changes: [
            .add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", observed: nil, confidence: .stated, evidence: evidence("q")),
        ], since: other.generation, settings: on, now: t0)
        XCTAssertTrue(other.notes.isEmpty)
        XCTAssertTrue(other.queue.isEmpty)
    }

    func testForgetByTheModelLeavesATombstoneWithTheVector() {
        var file = MemoryFile()
        let n = file.add(subject: .user, topic: "work", kind: .fact, text: "Works at Acme", now: t0, reviewed: false, confidence: .stated)!
        file.notes[0].evidence = [evidence("acme")]
        let id = queued(&file)
        file.commit(batch: id, changes: [.forget(id: n, vector: [1, 0])], since: file.generation, settings: on, now: t0)
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
}
