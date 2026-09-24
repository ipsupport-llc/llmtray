import XCTest
@testable import LLMTrayCore

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "llmtray.tests.preferences"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsWhenUnset() {
        XCTAssertEqual(defaults[Pref.port], 8765)
        XCTAssertTrue(defaults[Pref.checkUpdatesAtLaunch])
        XCTAssertNil(defaults[Pref.selectedModelID])
    }

    func testRoundTrip() {
        defaults[Pref.port] = 9000
        defaults[Pref.betaUpdates] = true
        defaults[Pref.selectedModelID] = "/m/a"
        XCTAssertEqual(defaults[Pref.port], 9000)
        XCTAssertEqual(defaults.integer(forKey: "llmtray.port"), 9000)   // same key @AppStorage reads
        XCTAssertTrue(defaults[Pref.betaUpdates])
        XCTAssertEqual(defaults[Pref.selectedModelID], "/m/a")
        defaults[Pref.selectedModelID] = nil
        XCTAssertNil(defaults.object(forKey: "selectedModelID"))
    }

    func testWrongStoredTypeFallsBackToDefault() {
        defaults.set("not a number", forKey: "llmtray.port")
        XCTAssertEqual(defaults[Pref.port], 8765)
    }
}

final class OperationAvailabilityTests: XCTestCase {
    private func ops(_ server: ActivitySnapshot.Server, serverBusy: Bool = false, chatBusy: Bool = false, bench: Bool = false) -> OperationAvailability {
        OperationAvailability(ActivitySnapshot(server: server, serverBusy: serverBusy, chatBusy: chatBusy, benchmarkRunning: bench))
    }

    func testRestart() {
        XCTAssertTrue(ops(.running).canRestartServer)
        XCTAssertFalse(ops(.running, serverBusy: true).canRestartServer)
        XCTAssertFalse(ops(.running, chatBusy: true).canRestartServer)
        XCTAssertFalse(ops(.running, bench: true).canRestartServer)
        XCTAssertFalse(ops(.idleUnloaded).canRestartServer)
    }

    func testProfileAssignment() {
        XCTAssertTrue(ops(.running, serverBusy: true).canAssignProfile(toLoadedModel: false))
        XCTAssertFalse(ops(.running, serverBusy: true).canAssignProfile(toLoadedModel: true))
        XCTAssertFalse(ops(.starting).canAssignProfile(toLoadedModel: true))
        XCTAssertFalse(ops(.stopped, bench: true).canAssignProfile(toLoadedModel: false))
        XCTAssertTrue(ops(.idleUnloaded).canAssignProfile(toLoadedModel: true))
    }

    func testNetworkAndRuntimeOnlyWhenNothingCanListenOrLoad() {
        for s: ActivitySnapshot.Server in [.stopped, .failed] {
            XCTAssertTrue(ops(s).canEditNetworkSettings)
            XCTAssertTrue(ops(s).canChangeRuntime)
        }
        for s: ActivitySnapshot.Server in [.idleUnloaded, .starting, .running] {
            XCTAssertFalse(ops(s).canEditNetworkSettings, "\(s)")
            XCTAssertFalse(ops(s).canChangeRuntime, "\(s)")
        }
    }

    func testModelSwitchAndProfileEditing() {
        XCTAssertFalse(ops(.starting).canSwitchModel)
        XCTAssertFalse(ops(.running, bench: true).canSwitchModel)
        XCTAssertTrue(ops(.running, chatBusy: true).canSwitchModel)
        XCTAssertFalse(ops(.running, bench: true).canEditProfiles)
        XCTAssertFalse(ops(.stopped, chatBusy: true).canDeleteProfile)
    }
}
