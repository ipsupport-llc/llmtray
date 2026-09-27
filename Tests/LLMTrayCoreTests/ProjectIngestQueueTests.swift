import XCTest
@testable import LLMTrayCore

final class ProjectIngestQueueTests: XCTestCase {
    typealias Q = ProjectIngestQueue
    let a = UUID(), b = UUID()

    func testExtractionComesFirstEverywhereThenEmbedding() {
        var q = Q()
        q.enqueue([.embed(1)], in: a)
        q.enqueue([.extract(2), .extract(3)], in: a)
        q.enqueue([.extract(7)], in: b)
        var order: [Q.Item] = []
        while let item = q.next() {
            order.append(item)
            q.finish(item, .finished)
        }
        XCTAssertEqual(order.map(\.work), [.extract(2), .extract(7), .extract(3), .embed(1)],
                       "every extraction before any embedding, projects taking turns, documents in order")
    }

    func testOneStepAtATime() {
        var q = Q()
        q.enqueue([.extract(1), .extract(2)], in: a)
        let first = q.next()
        XCTAssertNotNil(first)
        XCTAssertNil(q.next(), "nothing else while a step is in flight")
        q.finish(first!, .finished)
        XCTAssertEqual(q.next()?.work, .extract(2))
    }

    func testExtractedDocumentsQueueTheirEmbeddingAndCountOnce() {
        var q = Q()
        q.enqueue([.extract(1), .extract(2)], in: a)
        let one = q.next()!
        XCTAssertFalse(q.finish(one, .needsEmbedding, seconds: 1))
        var p = q.progress(a)
        XCTAssertEqual(p.total, 2)
        XCTAssertEqual(p.done, 0, "not done until embedded")
        let two = q.next()!
        XCTAssertEqual(two.work, .extract(2), "extraction before the queued embedding")
        q.finish(two, .failed, seconds: 1)
        let embed = q.next()!
        XCTAssertEqual(embed.work, .embed(1))
        p = q.progress(a)
        XCTAssertEqual(p.state, .running)
        XCTAssertEqual(p.failed, 1)
        XCTAssertTrue(q.finish(embed, .finished, seconds: 2), "the run ends when nothing is left")
        XCTAssertEqual(q.progress(a), .idle, "counters reset for the next run")
    }

    func testDuplicatesAreSkipped() {
        var q = Q()
        q.enqueue([.extract(1), .extract(1)], in: a)
        let item = q.next()!
        q.enqueue([.extract(1)], in: a)   // the one in flight
        q.finish(item, .finished)
        XCTAssertNil(q.next())
    }

    func testQueuedAgainWhileItRanAndDroppedRunsAgain() {
        var q = Q()
        q.enqueue([.extract(1)], in: a)
        let item = q.next()!
        q.stop(a)                         // cancels it
        q.enqueue([.extract(1)], in: a)   // Index Now before it ended
        q.finish(item, .dropped)
        XCTAssertEqual(q.next(), item, "run again")
        XCTAssertEqual(q.progress(a).total, 1)
    }

    func testPausedProjectsWaitAndOthersRun() {
        var q = Q()
        q.enqueue([.extract(1)], in: a)
        q.enqueue([.extract(2)], in: b)
        q.setPaused(a, true)
        let item = q.next()!
        XCTAssertEqual(item.project, b)
        q.finish(item, .finished)
        XCTAssertNil(q.next(), "a's work waits for Resume")
        XCTAssertEqual(q.progress(a).state, .paused)
        q.setPaused(a, false)
        XCTAssertEqual(q.next()?.project, a)
    }

    func testInterruptedGoesBackToTheFront() {
        var q = Q()
        q.enqueue([.embed(1), .embed(2)], in: a)
        let item = q.next()!
        q.finish(item, .interrupted)
        XCTAssertEqual(q.next()?.work, .embed(1))
    }

    func testStopClearsTheQueueAndTheRun() {
        var q = Q()
        q.enqueue([.extract(1), .extract(2), .extract(3)], in: a)
        let item = q.next()!
        XCTAssertTrue(q.stop(a), "its step is in flight")
        XCTAssertEqual(q.queued(a), [])
        q.finish(item, .dropped)
        XCTAssertNil(q.next())
        XCTAssertEqual(q.progress(a), .idle)
    }

    func testRemoveForgetsTheProject() {
        var q = Q()
        q.enqueue([.extract(1)], in: a)
        q.enqueue([.extract(2)], in: b)
        q.remove(a)
        XCTAssertEqual(q.next()?.project, b)
        XCTAssertFalse(q.hasWork(a))
    }

    func testDropTakesOneDocumentOut() {
        var q = Q()
        q.enqueue([.extract(1), .extract(2)], in: a)
        q.drop(1, in: a)
        XCTAssertEqual(q.queued(a), [.extract(2)])
        XCTAssertEqual(q.progress(a).total, 1)
    }

    func testBlockedEmbeddingLetsExtractionThrough() {
        var q = Q()
        q.enqueue([.embed(1)], in: a)
        q.embeddingBlocked = true
        XCTAssertNil(q.next())
        q.enqueue([.extract(2)], in: a)
        XCTAssertEqual(q.next()?.work, .extract(2))
    }

    func testWordsOnlyFinishesQueuedEmbeddings() {
        var q = Q()
        q.enqueue([.embed(1), .embed(2)], in: a)
        q.enqueue([.embed(3)], in: b)
        let item = q.next()!
        XCTAssertEqual(q.finishEmbeddingAsWordsOnly(), [b], "a still has its step in flight")
        XCTAssertEqual(q.progress(a).done, 1)
        XCTAssertTrue(q.finish(item, .finished))
    }

    func testProgressEstimatesTheTimeLeft() {
        var q = Q()
        q.enqueue([.extract(1), .extract(2), .extract(3)], in: a)
        XCTAssertNil(q.progress(a).remainingSeconds, "nothing finished yet")
        let item = q.next()!
        q.finish(item, .finished, seconds: 4)
        let p = q.progress(a, stage: .reading)
        XCTAssertEqual(p.remainingSeconds ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(p.stage, .reading)
        XCTAssertEqual(q.progress(a, waiting: true).state, .running, "waiting only for the step in flight")
    }

    func testDisplayStatusMapping() {
        XCTAssertEqual(DocumentDisplayStatus(.searchable), .readyWordsOnly)
        XCTAssertEqual(DocumentDisplayStatus(.searchable, embeddingQueued: true), .embedding)
        XCTAssertEqual(DocumentDisplayStatus(.embedded), .ready)
        XCTAssertEqual(DocumentDisplayStatus(.staged), .queued)
        XCTAssertEqual(DocumentDisplayStatus(.staged, activity: .reading), .reading)
        XCTAssertEqual(DocumentDisplayStatus(.unsupported), .notSupported)
        XCTAssertEqual(DocumentDisplayStatus(.notIndexed), .notIndexed)
    }

    func testFormatsOffered() {
        for name in ["a.txt", "b.MD", "c.swift", "d.pdf", "e.docx", "f.doc", "g.odt", "h.rtf", "i.html", "Makefile", "j.csv"] {
            XCTAssertTrue(ProjectFileFormats.isOffered(URL(fileURLWithPath: "/x/" + name)), name)
        }
        for name in ["a.xlsx", "b.pptx", "c.xls", "d.ppt", "e.png", "f.jpg", "g.zip", "h.mp3", "i.heic"] {
            XCTAssertFalse(ProjectFileFormats.isOffered(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }
}
