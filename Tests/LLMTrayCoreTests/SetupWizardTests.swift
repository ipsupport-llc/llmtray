import XCTest
@testable import LLMTrayCore

final class SetupWizardTests: XCTestCase {
    private let base = SetupChoices(modelsFolder: "/Users/me/.llmtray/models")

    // MARK: When it opens

    func testOpensOnAFreshInstallOnly() {
        XCTAssertTrue(SetupWizard.opensAutomatically(completedVersion: nil, selectedModelID: nil, saved: nil))
        XCTAssertFalse(SetupWizard.opensAutomatically(completedVersion: nil, selectedModelID: "/m/org/model", saved: nil),
                       "an existing user (a model selected) never gets it on their own")
        XCTAssertFalse(SetupWizard.opensAutomatically(completedVersion: 1, selectedModelID: nil, saved: nil),
                       "done (finished, skipped or closed) doesn't come back")
    }

    func testAFirstRunQuitPartWayOpensAgain() {
        let firstRun = SetupProgress(step: .extras, choices: base, startedAutomatically: true)
        XCTAssertTrue(SetupWizard.opensAutomatically(completedVersion: nil, selectedModelID: "/m/org/picked", saved: firstRun),
                      "the model picked in it doesn't stop it resuming")
        let manual = SetupProgress(step: .extras, choices: base, startedAutomatically: false)
        XCTAssertFalse(SetupWizard.opensAutomatically(completedVersion: nil, selectedModelID: "/m/org/model", saved: manual),
                       "one opened from Settings doesn't come back by itself")
        XCTAssertFalse(SetupWizard.opensAutomatically(completedVersion: 1, selectedModelID: nil, saved: firstRun))
    }

    // MARK: Resuming

    func testResumesAFirstRunWhereItWas() throws {
        var choices = base
        choices.webTools = true
        let saved = SetupProgress(step: .apps, choices: choices, startedAutomatically: true, startsServer: true)
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SetupProgress.self, from: data)
        XCTAssertEqual(decoded, saved, "survives the round trip through Pref.onboardingProgress")
        let resumed = SetupWizard.resume(saved: decoded, current: base, automatic: true)
        XCTAssertEqual(resumed.step, .apps)
        XCTAssertTrue(resumed.choices.webTools)
        XCTAssertTrue(resumed.startsServer)
    }

    func testOpenedByHandStartsFromTheCurrentSettings() {
        var current = base
        current.port = 9000
        let saved = SetupProgress(step: .apps, choices: base, startedAutomatically: true)
        let opened = SetupWizard.resume(saved: saved, current: current, automatic: false)
        XCTAssertEqual(opened.step, .welcome)
        XCTAssertEqual(opened.choices.port, 9000)
        XCTAssertEqual(opened.baseline, current)
        XCTAssertFalse(opened.startedAutomatically)
        XCTAssertEqual(SetupWizard.resume(saved: nil, current: current, automatic: true).step, .welcome)
    }

    /// A first run offers usage statistics ticked; opened by hand, as is.
    /// Ticked isn't on: only Finish applies it (it differs from the baseline).
    func testUsageStatisticsTickedOnAFirstRunOnly() {
        var current = base
        current.usageStatistics = false
        let first = SetupWizard.resume(saved: nil, current: current, automatic: true)
        XCTAssertTrue(first.choices.usageStatistics)
        XCTAssertFalse(first.baseline.usageStatistics)
        XCTAssertFalse(first.original.usageStatistics)
        XCTAssertFalse(SetupWizard.resume(saved: nil, current: current, automatic: false).choices.usageStatistics)
    }

    func testStepsInOrder() {
        XCTAssertEqual(SetupStep.allCases.first, .welcome)
        XCTAssertEqual(SetupStep.allCases.last, .done)
        XCTAssertEqual(SetupStep.chatModel.next, .extras)
        XCTAssertEqual(SetupStep.chatModel.previous, .modelsFolder)
        XCTAssertNil(SetupStep.done.next)
        XCTAssertNil(SetupStep.welcome.previous)
    }

    // MARK: Skip and early steps

    func testSkipPutsTheStepBack() {
        var progress = SetupProgress(step: .extras, choices: base, startedAutomatically: true)
        progress.choices.imageModel = "gptqMixed"
        progress.choices.webTools = true
        progress.choices.port = 9000   // another step's choice stays
        XCTAssertEqual(progress.skip(), [], "nothing was applied early")
        XCTAssertEqual(progress.step, .apps)
        XCTAssertNil(progress.choices.imageModel)
        XCTAssertFalse(progress.choices.webTools)
        XCTAssertEqual(progress.choices.port, 9000)
    }

    func testEarlyStepsAreNotRepeatedAtFinish() {
        var progress = SetupProgress(step: .modelsFolder, choices: base, startedAutomatically: true)
        progress.choices.modelsFolder = "/Users/me/.lmstudio/models"
        progress.choices.webTools = true
        XCTAssertEqual(progress.applyEarly(.modelsFolder), [.setModelsFolder("/Users/me/.lmstudio/models")],
                       "only that step's fields")
        progress.choices.chatModel = .download(repo: "org/model", approxBytes: 5)
        XCTAssertEqual(progress.applyEarly(.chatModel), [.downloadChatModel(repo: "org/model", approxBytes: 5)])
        XCTAssertEqual(progress.applyEarly(.chatModel), [], "picked once, downloaded once")
        XCTAssertEqual(SetupPlan.actions(from: progress.choices, baseline: progress.baseline, startsServer: true),
                       [.setWebTools(true), .startServer])
    }

    // MARK: The plan

    func testNothingChosenDoesNothing() {
        XCTAssertEqual(SetupPlan.actions(from: base, baseline: base, startsServer: false), [])
        XCTAssertEqual(SetupPlan.actions(from: base, baseline: base, startsServer: true), [],
                       "no chat model, no server start")
    }

    func testChoicesInOrder() {
        var c = base
        c.modelsFolder = "/lm"
        c.chatModel = .download(repo: "org/chat", approxBytes: 100)
        c.imageModel = "gptqMixed"
        c.editModel = "klein4b"
        c.musicModel = "turbo"
        c.creatorMode = true
        c.creatorCountdown = 5
        c.webTools = true
        c.projectFiles = true
        c.port = 9000
        c.allowLAN = true
        c.modelSwitchPolicy = ModelSwitchPolicy.ask.rawValue
        c.launchAtLogin = true
        c.automaticUpdateChecks = false
        c.checkUpdatesAtLaunch = false
        c.betaUpdates = true
        c.usageStatistics = true
        let actions = SetupPlan.actions(from: c, baseline: base, startsServer: true)
        XCTAssertEqual(actions, [
            .setModelsFolder("/lm"),
            .setPort(9000), .setAllowLAN(true), .setModelSwitchPolicy("ask"),
            .setCreatorMode(true), .setCreatorCountdown(5), .setWebTools(true),
            .setProjectFiles(true),
            .setLaunchAtLogin(true), .setAutomaticUpdateChecks(false), .setCheckUpdatesAtLaunch(false),
            .setBetaUpdates(true), .setUsageStatistics(true),
            .downloadChatModel(repo: "org/chat", approxBytes: 100),
            .downloadImageModel("gptqMixed"), .downloadEditModel("klein4b"), .downloadMusicModel("turbo"),
            .downloadEmbedder,
            .startServer,
        ])
        XCTAssertEqual(actions.filter(\.isDownload).count, 5)
        XCTAssertEqual(actions.last, .startServer, "the server starts after everything else is set")
    }

    func testALocalModelIsSelectedNotDownloaded() {
        var c = base
        c.chatModel = .local(path: "/m/org/model")
        XCTAssertEqual(SetupPlan.actions(from: c, baseline: base, startsServer: true), [.selectModel(path: "/m/org/model"), .startServer])
    }

    func testTurningOffWhatWasOn() {
        var on = base
        on.imageModel = "gptqMixed"
        on.editModel = "klein4b"
        on.musicModel = "turbo"
        on.projectFiles = true
        on.chatModel = .local(path: "/m/a")
        var off = on
        off.imageModel = nil
        off.editModel = nil
        off.musicModel = nil
        off.projectFiles = false
        off.chatModel = nil
        XCTAssertEqual(SetupPlan.actions(from: off, baseline: on, startsServer: false),
                       [.disableImageGeneration, .disableImageEditing, .disableMusicGeneration, .setProjectFiles(false)],
                       "no chat model picked leaves the selection alone")
    }

    func testAnotherModelOfAFeatureAlreadyOnIsDownloaded() {
        var on = base
        on.musicModel = "turbo"
        var other = on
        other.musicModel = "sft8bit"
        XCTAssertEqual(SetupPlan.actions(from: other, baseline: on, startsServer: false), [.downloadMusicModel("sft8bit")])
    }

    func testNegativeCountdownIsClamped() {
        var c = base
        c.creatorCountdown = -2
        XCTAssertEqual(SetupPlan.actions(from: c, baseline: base, startsServer: false), [.setCreatorCountdown(0)])
    }

    func testSkipUndoesAPickedDownload() {
        var progress = SetupProgress(step: .chatModel, choices: base, startedAutomatically: true)
        progress.choices.chatModel = .download(repo: "org/model", approxBytes: 5)
        progress.startsServer = true
        _ = progress.applyEarly(.chatModel)
        XCTAssertEqual(progress.skip(), [.cancelChatDownload(repo: "org/model"), .clearModelSelection])
        XCTAssertNil(progress.choices.chatModel)
        XCTAssertFalse(progress.startsServer, "no server start for a pick that was undone")
        XCTAssertEqual(SetupPlan.actions(from: progress.choices, baseline: progress.baseline, startsServer: progress.startsServer), [])
    }

    func testSkipPutsTheOpeningSelectionBack() {
        var opened = base
        opened.chatModel = .local(path: "/m/a")
        var progress = SetupProgress(step: .chatModel, choices: opened, startedAutomatically: false)
        progress.choices.chatModel = .local(path: "/m/b")
        progress.startsServer = true
        XCTAssertEqual(progress.applyEarly(.chatModel), [.selectModel(path: "/m/b")])
        XCTAssertEqual(progress.skip(), [.selectModel(path: "/m/a")])
        XCTAssertFalse(progress.startsServer)

        var fresh = SetupProgress(step: .chatModel, choices: base, startedAutomatically: true)
        fresh.choices.chatModel = .local(path: "/m/b")
        _ = fresh.applyEarly(.chatModel)
        XCTAssertEqual(fresh.skip(), [.clearModelSelection])
    }

    func testSkipAfterALocalPickThenADownloadClearsTheSelection() {
        var fresh = SetupProgress(step: .chatModel, choices: base, startedAutomatically: true)
        fresh.choices.chatModel = .local(path: "/m/b")
        XCTAssertEqual(fresh.applyEarly(.chatModel), [.selectModel(path: "/m/b")])
        fresh.choices.chatModel = .download(repo: "org/model", approxBytes: nil)
        XCTAssertEqual(fresh.applyEarly(.chatModel), [.downloadChatModel(repo: "org/model", approxBytes: nil)])
        XCTAssertEqual(fresh.skip(), [.cancelChatDownload(repo: "org/model"), .clearModelSelection],
                       "the local pick doesn't stay selected")
        XCTAssertNil(fresh.choices.chatModel)
        XCTAssertNil(fresh.baseline.chatModel)

        // Opened with a selection: that one again.
        var opened = base
        opened.chatModel = .local(path: "/m/a")
        var progress = SetupProgress(step: .chatModel, choices: opened, startedAutomatically: false)
        progress.choices.chatModel = .local(path: "/m/b")
        _ = progress.applyEarly(.chatModel)
        progress.choices.chatModel = .download(repo: "org/model", approxBytes: nil)
        _ = progress.applyEarly(.chatModel)
        XCTAssertEqual(progress.skip(), [.cancelChatDownload(repo: "org/model"), .selectModel(path: "/m/a")])
    }

    func testSkipPutsAnAppliedFolderBack() {
        var progress = SetupProgress(step: .modelsFolder, choices: base, startedAutomatically: true)
        progress.choices.modelsFolder = "/lm"
        _ = progress.applyEarly(.modelsFolder)
        progress.step = .modelsFolder   // back to it
        XCTAssertEqual(progress.skip(), [.setModelsFolder(base.modelsFolder)])
        XCTAssertEqual(progress.choices.modelsFolder, base.modelsFolder)
        XCTAssertEqual(progress.baseline.modelsFolder, base.modelsFolder)
    }

    func testProgressSavedWithoutTheOpeningSettingsStillResumes() throws {
        let saved = SetupProgress(step: .extras, choices: base, startedAutomatically: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        json["original"] = nil
        let decoded = try JSONDecoder().decode(SetupProgress.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.original, decoded.baseline)
        XCTAssertEqual(decoded.step, .extras)
    }

    // MARK: A port another app holds

    func testAnAdoptedPortIsAppliedAtOnceAndSurvivesSkip() {
        var progress = SetupProgress(step: .apps, choices: base, startedAutomatically: true)
        XCTAssertEqual(progress.adoptPort(8766), [.setPort(8766)])
        XCTAssertEqual(progress.adoptPort(8766), [], "already set")
        XCTAssertTrue(SetupPlan.actions(from: progress.choices, baseline: progress.baseline, startsServer: false).isEmpty,
                      "Finish doesn't set it again")
        _ = progress.skip()
        XCTAssertEqual(progress.choices.port, 8766, "Skip doesn't go back to the taken port")
    }
}
