import XCTest
@testable import LLMTrayCore

final class MemoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let on = MemorySettings(enabled: true)
    /// One token per 4 bytes: easy to reason about in budgets.
    let tokens: (String) -> Int = { ($0.utf8.count + 3) / 4 }

    func days(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    // MARK: Store

    func testRoundTripAndSubjectEncoding() throws {
        var file = MemoryFile()
        let project = UUID()
        file.add(subject: .user, topic: "Answer Length", kind: .preference, text: "Short answers", now: t0)
        file.add(subject: .project(project), topic: "work", kind: .fact, text: "Builds an ESP32 speaker", now: t0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"user\""))
        XCTAssertTrue(json.contains("project:" + project.uuidString))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MemoryFile.self, from: data), file)
        XCTAssertEqual(file.notes[0].topic, "answer-length")
        XCTAssertEqual(file.notes.map(\.id), ["m1", "m2"])
    }

    func testAddRefusesWhatCantBeANote() {
        var file = MemoryFile()
        XCTAssertNil(file.add(subject: .user, topic: "x", kind: .fact, text: "   ", now: t0))
        XCTAssertNil(file.add(subject: .user, topic: "x", kind: .fact, text: "See https://example.com", now: t0))
        XCTAssertEqual(file.generation, 0)
        XCTAssertTrue(file.notes.isEmpty)
    }

    func testTextProblems() {
        XCTAssertNil(MemoryText.problem("Prefers short answers in Russian"))
        XCTAssertNil(MemoryText.problem("Uses macOS on an M5 with 26 GB"))
        XCTAssertEqual(MemoryText.problem(String(repeating: "a", count: 161)), .tooLong)
        XCTAssertEqual(MemoryText.problem("Docs at www.example.com"), .link)
        XCTAssertEqual(MemoryText.problem("Keeps work in ~/gh/llmtray"), .path)
        XCTAssertEqual(MemoryText.problem("Repo is /Users/me/code"), .path)
        XCTAssertEqual(MemoryText.problem("Token hf_abcdefghijklmnop"), .secret)
        XCTAssertEqual(MemoryText.problem("Key " + String(repeating: "Ab3", count: 12)), .secret)
    }

    func testEditKeepsThreeOldTextsAndMarksChanged() {
        var file = MemoryFile()
        let id = file.add(subject: .user, topic: "tone", kind: .preference, text: "v0", now: t0, reviewed: false, confidence: .inferred)!
        for i in 1...4 { XCTAssertTrue(file.edit(id, text: "v\(i)", now: days(Double(i)))) }
        let note = file.note(id)!
        XCTAssertEqual(note.text, "v4")
        XCTAssertEqual(note.history.map(\.text), ["v1", "v2", "v3"])
        XCTAssertTrue(note.reviewed)
        XCTAssertEqual(note.confidence, .stated)
        XCTAssertEqual(note.changed, file.generation)
        XCTAssertFalse(file.edit("m99", text: "x", now: t0))
        XCTAssertFalse(file.edit(id, text: "http://x", now: t0))
    }

    func testForgetProjectOnlyTouchesThatProject() {
        var file = MemoryFile()
        let a = UUID(), b = UUID()
        file.add(subject: .project(a), topic: "work", kind: .fact, text: "A", now: t0)
        file.add(subject: .project(b), topic: "work", kind: .fact, text: "B", now: t0)
        file.add(subject: .user, topic: "tone", kind: .preference, text: "U", now: t0)
        let g = file.generation
        file.forget(project: a)
        XCTAssertEqual(file.notes.map(\.text), ["B", "U"])
        XCTAssertGreaterThan(file.generation, g)
        let g2 = file.generation
        file.forget(project: UUID())
        XCTAssertEqual(file.generation, g2, "nothing forgotten: no new generation")
    }

    // MARK: Expiry

    func testRecencyHalvesPerHalfLife() {
        var file = MemoryFile()
        let id = file.add(subject: .user, topic: "work", kind: .fact, text: "F", now: t0)!
        let note = file.note(id)!
        XCTAssertEqual(MemoryFile.recency(note, now: days(90), settings: on), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MemoryFile.recency(note, now: days(180), settings: on), 0.25, accuracy: 1e-9)
        file.setPinned(id, true, now: t0)
        XCTAssertEqual(MemoryFile.recency(file.note(id)!, now: days(10_000), settings: on), 1)
    }

    func testSweepExpiresFadedThenDeletesAfterGrace() {
        var file = MemoryFile()
        let obs = file.add(subject: .user, topic: "work", kind: .observation, text: "O", now: t0)!
        let pin = file.add(subject: .user, topic: "work", kind: .observation, text: "P", now: t0)!
        file.setPinned(pin, true, now: t0)
        let fact = file.add(subject: .user, topic: "work", kind: .fact, text: "F", now: t0)!
        // 3.3 half-lives of an observation (30 days) is under the floor.
        XCTAssertTrue(file.sweep(now: days(100), settings: on))
        XCTAssertNotNil(file.note(obs)?.expired)
        XCTAssertNil(file.note(pin)?.expired)
        XCTAssertNil(file.note(fact)?.expired)
        XCTAssertFalse(file.sweep(now: days(101), settings: on), "nothing new to do")
        file.restore(obs, now: days(110))
        XCTAssertNil(file.note(obs)?.expired)
        XCTAssertTrue(file.sweep(now: days(210), settings: on))
        XCTAssertNotNil(file.note(obs)?.expired)
        // Deleted once the grace period (30 days) has passed.
        file.sweep(now: days(241), settings: on)
        XCTAssertNil(file.note(obs))
        XCTAssertNotNil(file.note(pin))
    }

    func testCapExpiresTheWeakestUnpinned() {
        var settings = on
        settings.maxActive = 2
        var file = MemoryFile()
        let old = file.add(subject: .user, topic: "work", kind: .fact, text: "old", now: t0)!
        let guess = file.add(subject: .user, topic: "work", kind: .fact, text: "guess", now: days(10), reviewed: false, confidence: .inferred)!
        let fresh = file.add(subject: .user, topic: "work", kind: .fact, text: "fresh", now: days(10))!
        file.sweep(now: days(10), settings: settings)
        // old: 1.0 × 0.5^(10/90) ≈ 0.93; guess: 0.6 × 1 — the guess goes.
        XCTAssertNotNil(file.note(guess)?.expired)
        XCTAssertNil(file.note(old)?.expired)
        XCTAssertNil(file.note(fresh)?.expired)
    }

    // MARK: Choice

    func testChooseOrdersPinnedAndStatedPreferencesFirst() {
        var file = MemoryFile()
        file.add(subject: .user, topic: "work", kind: .fact, text: "A fact", now: days(5))
        let pref = file.add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", now: t0)!
        let pin = file.add(subject: .user, topic: "work", kind: .fact, text: "Pinned fact", now: t0)!
        file.setPinned(pin, true, now: t0)
        let snap = MemorySelection.choose(file, settings: on, project: nil, budget: 1000, now: days(5), tokens: tokens)!
        XCTAssertEqual(snap.noteIDs, [pin, pref, "m1"])
        XCTAssertTrue(snap.text.hasPrefix(MemorySelection.header))
        XCTAssertEqual(snap.generation, file.generation)
        XCTAssertEqual(snap.tokens, tokens(snap.text))
    }

    func testChooseRespectsEligibility() {
        var file = MemoryFile()
        let project = UUID()
        file.add(subject: .user, topic: "work", kind: .fact, text: "User fact", now: t0)
        file.add(subject: .project(project), topic: "work", kind: .fact, text: "Project fact", now: t0)
        file.add(subject: .project(UUID()), topic: "work", kind: .fact, text: "Other project", now: t0)
        file.add(subject: .user, topic: "tone", kind: .observation, text: "Likes tables", observed: "Asked for tables twice", now: t0,
                 confidence: .inferred)
        let all = MemorySelection.choose(file, settings: on, project: project, budget: 1000, now: t0, tokens: tokens)!
        XCTAssertTrue(all.text.contains("User fact"))
        XCTAssertTrue(all.text.contains(MemorySelection.projectHeader + "\n- Project fact"))
        XCTAssertFalse(all.text.contains("Other project"))
        XCTAssertTrue(all.text.contains("- Observed: Asked for tables twice; likely: Likes tables (a guess)"))

        var noProjects = on
        noProjects.projectMemory = false
        XCTAssertFalse(MemorySelection.choose(file, settings: noProjects, project: project, budget: 1000, now: t0, tokens: tokens)!
            .text.contains("Project fact"))
        var factsOff = on
        factsOff.kinds = [.observation]
        XCTAssertEqual(MemorySelection.choose(file, settings: factsOff, project: project, budget: 1000, now: t0, tokens: tokens)!
            .noteIDs, ["m4"])
        XCTAssertNil(MemorySelection.choose(file, settings: MemorySettings(enabled: false), project: nil, budget: 1000, now: t0, tokens: tokens))
        XCTAssertNil(MemorySelection.choose(MemoryFile(), settings: on, project: nil, budget: 1000, now: t0, tokens: tokens))
    }

    func testChooseSkipsWhatDoesntFitAndTriesTheNext() {
        var file = MemoryFile()
        file.add(subject: .user, topic: "work", kind: .fact, text: String(repeating: "long ", count: 30), now: days(2))
        file.add(subject: .user, topic: "work", kind: .fact, text: "Short", now: days(1))
        let headerTokens = tokens(MemorySelection.header)
        let snap = MemorySelection.choose(file, settings: on, project: nil, budget: headerTokens + 6, now: days(2), tokens: tokens)!
        XCTAssertEqual(snap.noteIDs, ["m2"])
        XCTAssertLessThanOrEqual(snap.tokens, headerTokens + 6)
        XCTAssertNil(MemorySelection.choose(file, settings: on, project: nil, budget: headerTokens, now: days(2), tokens: tokens))
    }

    func testFirstGroupTakesAtMostHalfTheBudget() {
        var file = MemoryFile()
        for i in 0..<20 { file.add(subject: .user, topic: "tone", kind: .preference, text: "Preference number \(i)", now: t0) }
        // A fresher fact: first of the rest, but only if the preferences
        // left room -- they get at most half before the rest is ranked.
        file.add(subject: .user, topic: "work", kind: .fact, text: "Fact", now: days(1))
        let budget = tokens(MemorySelection.header) + 60
        let snap = MemorySelection.choose(file, settings: on, project: nil, budget: budget, now: days(1), tokens: tokens)!
        XCTAssertTrue(snap.noteIDs.contains("m21"))
        XCTAssertLessThanOrEqual(snap.tokens, budget)
        let firstPass = snap.noteIDs.prefix { $0 != "m21" }
        XCTAssertLessThanOrEqual(tokens(MemorySelection.render(firstPass.map { file.note($0)! })), budget / 2)
    }

    // MARK: Snapshot

    func testSnapshotStaysUntilOneOfItsNotesChanges() {
        var file = MemoryFile()
        let project = UUID()
        let id = file.add(subject: .user, topic: "tone", kind: .preference, text: "Be brief", now: t0)!
        let snap = MemorySelection.choose(file, settings: on, project: project, budget: 1000, now: t0, tokens: tokens)!
        func current(_ f: MemoryFile, settings: MemorySettings? = nil, project p: UUID? = nil, budget: Int = 1000) -> Bool {
            MemorySelection.isCurrent(snap, file: f, settings: settings ?? on, project: p ?? project, budget: budget)
        }
        XCTAssertTrue(current(file))

        var added = file
        added.add(subject: .user, topic: "work", kind: .fact, text: "New", now: t0)
        XCTAssertTrue(current(added), "a new note waits for the next chat")

        var edited = file
        edited.edit(id, text: "Be very brief", now: t0)
        XCTAssertFalse(current(edited))

        var forgotten = file
        forgotten.forget(id)
        XCTAssertFalse(current(forgotten))

        var kindsOff = on
        kindsOff.kinds = [.fact]
        XCTAssertFalse(current(file, settings: kindsOff))
        XCTAssertFalse(current(file, settings: MemorySettings(enabled: false)))
        XCTAssertFalse(current(file, project: UUID()), "moved to another project")
        XCTAssertFalse(current(file, budget: snap.tokens - 1))

        var expired = file
        expired.sweep(now: days(2000), settings: on)
        XCTAssertFalse(current(expired))
    }

    // MARK: Settings, system prompt

    func testSettingsFromDefaults() {
        let defaults = UserDefaults(suiteName: "MemoryTests-\(UUID().uuidString)")!
        XCTAssertEqual(MemorySettings(defaults: defaults), MemorySettings())
        defaults[Pref.memoryEnabled] = true
        MemorySettings.storeKinds([.correction, .fact], defaults: defaults)
        defaults[Pref.memoryHalfLifeFact] = 0
        defaults[Pref.memoryBudgetTokens] = 500
        let s = MemorySettings(defaults: defaults)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.kinds, [.correction, .fact])
        XCTAssertEqual(defaults[Pref.memoryKinds], "fact,correction")
        XCTAssertEqual(s.halfLife(.fact), 1, "at least a day")
        XCTAssertEqual(s.budgetTokens, 500)
    }

    func testMemoryGoesAfterTheProfilePromptBeforeTheProject() {
        let project = ProjectContext(id: UUID(), name: "P", instructions: "Project rules.")
        XCTAssertEqual(chatSystemPrompt(profile: "Profile.", memory: "Memory.", project: project, toolUsePolicy: "Tools."),
                       "Profile.\n\nMemory.\n\nInstructions for this chat's project, \"P\":\nProject rules.\n\nTools.")
        XCTAssertEqual(chatSystemPrompt(profile: "Profile.", memory: "  ", project: nil, toolUsePolicy: nil), "Profile.")
    }
}
