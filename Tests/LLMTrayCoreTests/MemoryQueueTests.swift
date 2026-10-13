import XCTest
@testable import LLMTrayCore

final class MemoryQueueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let chat = UUID()

    func message(_ seq: Int, _ text: String, before: String? = nil) -> MemoryBatchMessage {
        MemoryBatchMessage(seq: seq, date: t0, text: text, before: before)
    }

    func testNothingIsQueuedForAChatMemoryHasntMet() {
        var file = MemoryFile()
        XCTAssertFalse(file.enqueue(chat: chat, project: nil, messages: [message(1, "hi")], now: t0))
        XCTAssertTrue(file.queue.isEmpty)
    }

    func testQueuesWhatsAfterTheWatermarkAndMovesIt() {
        var file = MemoryFile()
        file.meet(chat, from: 2)
        file.meet(chat, from: 0)   // met once: kept
        XCTAssertEqual(file.watermark(chat), 2)
        let project = UUID()
        XCTAssertTrue(file.enqueue(chat: chat, project: project, messages: [
            message(1, "old"), message(2, "older"), message(4, "four", before: String(repeating: "a", count: 500)),
            message(3, "three"), message(5, "   "),
        ], now: t0))
        XCTAssertEqual(file.queue.count, 1)
        let batch = file.queue[0]
        XCTAssertEqual(batch.messages.map(\.seq), [3, 4])
        XCTAssertEqual(batch.messages[1].before?.count, MemoryBatchMessage.maxBefore)
        XCTAssertEqual(batch.project, project)
        XCTAssertEqual(file.watermark(chat), 4, "a blank message doesn't move it")
        XCTAssertFalse(file.enqueue(chat: chat, project: nil, messages: [message(3, "three"), message(4, "four")], now: t0))
    }

    func testLongChatsSplitIntoBatches() {
        var file = MemoryFile()
        file.meet(chat, from: 0)
        let long = String(repeating: "слово ", count: 600)   // ~6.6 KB
        file.enqueue(chat: chat, project: nil, messages: [message(1, long), message(2, long), message(3, "short")], now: t0)
        XCTAssertEqual(file.queue.map { $0.messages.map(\.seq) }, [[1], [2, 3]])
        XCTAssertEqual(Set(file.queue.map(\.id)).count, 2)
        // A paste bigger than a batch is cut to one.
        file.enqueue(chat: chat, project: nil, messages: [message(4, String(repeating: "x", count: 20_000))], now: t0)
        XCTAssertEqual(file.queue.last?.messages[0].text.utf8.count, MemoryBatch.maxBytes)
    }

    func testOptingOutDropsTheQueueAndStopsLearning() {
        var file = MemoryFile()
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: nil, messages: [message(1, "a")], now: t0)
        file.setOptedOut(chat, true)
        XCTAssertTrue(file.queue.isEmpty)
        XCTAssertNil(file.watermark(chat))
        file.meet(chat, from: 1)
        XCTAssertNil(file.watermark(chat), "not met while opted out")
        XCTAssertFalse(file.enqueue(chat: chat, project: nil, messages: [message(2, "said while opted out")], now: t0))
        // Remembered again: met anew at its next message, so message 2 is never read.
        file.setOptedOut(chat, false)
        XCTAssertFalse(file.enqueue(chat: chat, project: nil, messages: [message(2, "said while opted out")], now: t0))
        file.meet(chat, from: 2)
        file.enqueue(chat: chat, project: nil, messages: [message(2, "said while opted out"), message(3, "c")], now: t0)
        XCTAssertEqual(file.queue.flatMap { $0.messages.map(\.seq) }, [3])
    }

    func testMemoryOffForgetsWatermarksSoNothingSaidMeanwhileIsRead() {
        var file = MemoryFile()
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: nil, messages: [message(1, "a")], now: t0)
        file.forgetWatermarks()
        XCTAssertEqual(file.queue.count, 1, "what's queued stays")
        XCTAssertFalse(file.enqueue(chat: chat, project: nil, messages: [message(2, "said while off")], now: t0))
        file.meet(chat, from: 2)
        XCTAssertEqual(file.watermark(chat), 2)
    }

    func learned(_ file: inout MemoryFile, chats: [UUID], text: String, reviewed: Bool = false) -> String {
        let id = file.add(subject: .user, topic: "tone", kind: .preference, text: text, now: t0, reviewed: reviewed, confidence: .inferred)!
        let i = file.notes.firstIndex { $0.id == id }!
        file.notes[i].evidence = chats.map { MemoryEvidence(chat: $0, seq: 1, date: t0, quote: "quote from \($0)") }
        return id
    }

    func testForgettingAChatsLessons() {
        var file = MemoryFile()
        let other = UUID()
        file.meet(chat, from: 0)
        file.enqueue(chat: chat, project: nil, messages: [message(1, "a")], now: t0)
        let only = learned(&file, chats: [chat], text: "Only from it")
        let both = learned(&file, chats: [chat, other], text: "From both")
        let kept = learned(&file, chats: [chat], text: "Approved", reviewed: true)
        let g = file.generation
        file.forgetLearned(fromChat: chat, keepState: false)
        XCTAssertNil(file.note(only))
        XCTAssertEqual(file.note(both)?.evidence.map(\.chat), [other])
        XCTAssertEqual(file.note(kept)?.evidence, [])
        XCTAssertTrue(file.queue.isEmpty)
        XCTAssertNil(file.watermark(chat))
        XCTAssertGreaterThan(file.generation, g)
        XCTAssertTrue(file.tombstones.contains { $0.blocks(quote: "QUOTE  from \(chat)") })
        XCTAssertEqual(file.note(both)?.changed, file.notes.first { $0.id == both }?.changed, "evidence isn't the claim")
    }

    func testKeepingNotesAndState() {
        var file = MemoryFile()
        let out = UUID()
        file.meet(chat, from: 3)
        file.setOptedOut(out, true)
        let id = learned(&file, chats: [chat], text: "Kept")
        file.forgetLearned(fromChat: chat, keepState: true, keepNotes: true)
        file.forgetLearned(fromChat: out, keepState: true)
        XCTAssertNotNil(file.note(id))
        XCTAssertEqual(file.watermark(chat), 3)
        XCTAssertTrue(file.optedOut.contains(out))
    }

    func testForgettingALearnedNoteLeavesATombstone() {
        var file = MemoryFile()
        let manual = file.add(subject: .user, topic: "tone", kind: .preference, text: "Manual", now: t0)!
        file.forget(manual)
        XCTAssertTrue(file.tombstones.isEmpty, "nothing to recognise a hand-written note by")
        let id = learned(&file, chats: [chat], text: "Learned")
        file.forget(id, vector: [0.1, 0.2])
        XCTAssertEqual(file.tombstones.count, 1)
        XCTAssertEqual(file.tombstones[0].vector, [0.1, 0.2])
        XCTAssertFalse(file.tombstones[0].blocks(quote: "another quote"))
        let encoded = String(decoding: try! JSONEncoder().encode(file.tombstones), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Learned"))
        XCTAssertFalse(encoded.contains("quote from"))
    }

    func testForgetAllKeepsWatermarksAndOptOuts() {
        var file = MemoryFile()
        file.meet(chat, from: 5)
        file.enqueue(chat: chat, project: nil, messages: [message(6, "x")], now: t0)
        file.setOptedOut(UUID(), true)
        _ = learned(&file, chats: [chat], text: "x")
        file.forget(file.notes[0].id)
        file.forgetAll()
        XCTAssertTrue(file.notes.isEmpty && file.queue.isEmpty && file.tombstones.isEmpty)
        XCTAssertEqual(file.watermark(chat), 6)
        XCTAssertEqual(file.optedOut.count, 1)
    }

    func testAFileFromBeforeTheQueueStillReads() throws {
        let json = #"{"version":1,"generation":3,"nextID":2,"notes":[]}"#
        let file = try JSONDecoder().decode(MemoryFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.generation, 3)
        XCTAssertTrue(file.queue.isEmpty)
        XCTAssertEqual(file.nextBatchID, 1)
    }

    func testQuotesCompareFoldingCaseAndSpaces() {
        XCTAssertEqual(MemoryText.normalizedQuote("  Answer\n in   RUSSIAN "), "answer in russian")
        XCTAssertEqual(MemoryTombstone.hash("Answer in Russian"), MemoryTombstone.hash("answer  in\trussian"))
    }
}

extension MemoryQueueTests {
    func testMeetingRecordsWhereAndForgettingClearsIt() {
        var file = MemoryFile()
        file.meet(chat, from: 4)
        XCTAssertEqual(file.met(chat), 4)
        file.setOptedOut(chat, true)
        XCTAssertNil(file.met(chat))
        file.setOptedOut(chat, false)
        file.meet(chat, from: 9)
        XCTAssertEqual(file.met(chat), 9)
        file.forgetWatermarks()
        XCTAssertNil(file.met(chat))
    }
}

extension MemoryQueueTests {
    func testAFileWithWatermarksButNoMeetingPointsMeetsAtTheWatermark() throws {
        let id = UUID()
        let json = #"{"version":1,"generation":1,"nextID":1,"notes":[],"watermarks":{"\#(id.uuidString)":7}}"#
        let file = try JSONDecoder().decode(MemoryFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.met(id), 7)
    }
}
