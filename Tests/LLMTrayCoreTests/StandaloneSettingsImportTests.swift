import XCTest
@testable import LLMTrayCore

final class StandaloneSettingsImportTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "StandaloneSettingsImportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheFileIsTheStandalonesDomain() {
        XCTAssertEqual(StandaloneImport.settingsFileName, "us.ipsupport.llmtray.plist")
    }

    func testLLMTraysOwnSettingsComeOver() {
        for key in ["llmtray.port", "llmtray.modelsRoot", "llmtray.telemetry.enabled", "llmtray.onboarding.completedVersion",
                    "llmtray.systemPrompt", "selectedModelID", "AppleLanguages"] {
            XCTAssertTrue(StandaloneImport.isImportedSetting(key), key)
        }
    }

    func testStateUpdatesTelemetryIDsAndOthersKeysStay() {
        for key in ["llmtray.settingsPaneAfterRelaunch", "llmtray.onboarding.progress", "llmtray.downloadQueue",
                    "llmtray.openChatTabs", "llmtray.betaUpdates", "llmtray.checkUpdatesAtLaunch",
                    "llmtray.telemetry.installID", "llmtray.telemetry.lastSentDay", "llmtray.sandbox.bookmarks",
                    "llmtray.supporters.pendingListings", "SUEnableAutomaticChecks", "SULastCheckTime",
                    "NSWindow Frame Settings", "NSOSPLastRootDirectory", "AppleShowAllFiles", "WebKitDeveloperExtras"] {
            XCTAssertFalse(StandaloneImport.isImportedSetting(key), key)
        }
    }

    func testReadsABinaryPreferencesFile() throws {
        let file: [String: Any] = ["llmtray.port": 9000, "llmtray.allowLAN": true, "selectedModelID": "m",
                                   "llmtray.telemetry.installID": "abc", "NSWindow Frame x": "0 0 1 1"]
        let data = try PropertyListSerialization.data(fromPropertyList: file, format: .binary, options: 0)
        let settings = try XCTUnwrap(StandaloneImport.settings(fromPlist: data))
        XCTAssertEqual(Set(settings.keys), ["llmtray.port", "llmtray.allowLAN", "selectedModelID"])
        XCTAssertEqual(settings["llmtray.port"] as? Int, 9000)
    }

    func testSomethingElseIsNoPreferencesFile() {
        XCTAssertNil(StandaloneImport.settings(fromPlist: Data("not a plist".utf8)))
        let array = try! PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0)
        XCTAssertNil(StandaloneImport.settings(fromPlist: array))
    }

    func testTheirsReplaceOursAndOnlyChangesCount() {
        defaults.set(8765, forKey: "llmtray.port")
        defaults.set("mine", forKey: "llmtray.systemPrompt")
        defaults.set(true, forKey: "llmtray.allowLAN")
        let changed = StandaloneImport.apply(settings: ["llmtray.port": 9000, "llmtray.systemPrompt": "theirs",
                                                        "llmtray.allowLAN": true, "llmtray.temperature": 0.5],
                                             to: defaults)
        XCTAssertEqual(changed, 3)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.port"), 9000)
        XCTAssertEqual(defaults.string(forKey: "llmtray.systemPrompt"), "theirs")
        XCTAssertEqual(defaults.double(forKey: "llmtray.temperature"), 0.5)
        XCTAssertEqual(StandaloneImport.apply(settings: ["llmtray.port": 9000], to: defaults), 0)
    }
}
