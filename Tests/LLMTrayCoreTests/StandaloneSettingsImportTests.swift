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

    func testTheGettingStartedProjectsKeysStay() {
        // They name a project of this install's library.
        for key in [Pref.gettingStartedProject.name, Pref.gettingStartedGuidePending.name,
                    Pref.gettingStartedWrote.name, Pref.gettingStartedHidden.name] {
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
        defaults.set(true, forKey: "llmtray.kvSettingsMigrated.v1")
        let theirs: [String: Any] = ["llmtray.port": 9000, "llmtray.systemPrompt": "theirs", "llmtray.allowLAN": true,
                                     "llmtray.temperature": 0.5, "llmtray.kvSettingsMigrated.v1": true]
        XCTAssertEqual(StandaloneImport.apply(settings: theirs, to: defaults, domain: suite), 3)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.port"), 9000)
        XCTAssertEqual(defaults.string(forKey: "llmtray.systemPrompt"), "theirs")
        XCTAssertEqual(defaults.double(forKey: "llmtray.temperature"), 0.5)
        XCTAssertEqual(StandaloneImport.apply(settings: theirs, to: defaults, domain: suite), 0)
    }

    func testOursTheyDontHaveGoSoDefaultsMatch() {
        defaults.set(9000, forKey: "llmtray.port")
        defaults.set("mine", forKey: "llmtray.systemPrompt")
        // Not imported, so not ours to remove either.
        defaults.set("pane", forKey: "llmtray.settingsPaneAfterRelaunch")
        defaults.set(["/x": Data()], forKey: "llmtray.sandbox.bookmarks")
        defaults.set("frame", forKey: "NSWindow Frame Settings")
        StandaloneImport.apply(settings: ["llmtray.port": 9001, "llmtray.kvSettingsMigrated.v1": true], to: defaults, domain: suite)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.port"), 9001)
        XCTAssertNil(defaults.object(forKey: "llmtray.systemPrompt"))
        XCTAssertEqual(defaults.string(forKey: "llmtray.settingsPaneAfterRelaunch"), "pane")
        XCTAssertNotNil(defaults.object(forKey: "llmtray.sandbox.bookmarks"))
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame Settings"), "frame")
    }

    func testTheirValuesFromBeforeTheKVMigrationAreMigrated() {
        // This install migrated at launch; theirs predates the migration.
        KVSettings.migrateIfNeeded(defaults)
        StandaloneImport.apply(settings: ["llmtray.kvBits": 4, "llmtray.kvGroupSize": 48], to: defaults, domain: suite)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.kvBits"), KVSettings.defaultBits)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.kvGroupSize"), 32)
        XCTAssertTrue(defaults.bool(forKey: "llmtray.kvSettingsMigrated.v1"))
    }

    func testTheirMigratedValuesStay() {
        // A deliberate 4-bit choice after their migration isn't bumped.
        StandaloneImport.apply(settings: ["llmtray.kvBits": 4, "llmtray.kvSettingsMigrated.v1": true], to: defaults, domain: suite)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.kvBits"), 4)
    }

    func testOnlyThePreferencesFileItselfIsTaken() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let prefs = home.appendingPathComponent("Library/Preferences")
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let name = StandaloneImport.settingsFileName
        XCTAssertTrue(StandaloneImport.isStandalonePreferencesFile(prefs.appendingPathComponent(name), home: home.path))
        XCTAssertTrue(StandaloneImport.isStandalonePreferencesFile(URL(fileURLWithPath: prefs.path + "/../Preferences/" + name), home: home.path))
        XCTAssertFalse(StandaloneImport.isStandalonePreferencesFile(home.appendingPathComponent("Desktop/" + name), home: home.path))
        XCTAssertFalse(StandaloneImport.isStandalonePreferencesFile(prefs.appendingPathComponent("Old/" + name), home: home.path))
        XCTAssertFalse(StandaloneImport.isStandalonePreferencesFile(prefs.appendingPathComponent("other.plist"), home: home.path))
        // A link to a copy elsewhere is that copy.
        let elsewhere = home.appendingPathComponent(name)
        try Data().write(to: elsewhere)
        let link = prefs.appendingPathComponent(name)
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertFalse(StandaloneImport.isStandalonePreferencesFile(link, home: home.path))
    }
}
