import XCTest
@testable import LLMTrayCore

final class AppIdentityTests: XCTestCase {
    private let standalone = AppIdentity.standaloneBundleID
    private let appStore = AppIdentity.appStoreBundleID
    private let ownPID: Int32 = 100

    private func conflict(own: String?, _ running: [(String?, Int32)]) -> AppIdentity.Conflict? {
        AppIdentity.conflict(ownBundleID: own, ownPID: ownPID,
                             running: running.map { AppIdentity.Running(bundleID: $0.0, pid: $0.1) })
    }

    func testTheTwoBuildsHaveTheirOwnIDs() {
        XCTAssertEqual(standalone, "us.ipsupport.llmtray")
        XCTAssertEqual(appStore, "us.ipsupport.llmtray.appstore")
        #if APP_STORE
        XCTAssertEqual(AppIdentity.bundleID, appStore)
        #else
        XCTAssertEqual(AppIdentity.bundleID, standalone)
        #endif
    }

    func testPurchaseIDsDontFollowTheBundleID() {
        // App Store Connect and the supporters API know them by this prefix.
        for tier in SupporterTier.allCases {
            XCTAssertTrue(tier.productID.hasPrefix(standalone + ".tip."))
            XCTAssertFalse(tier.productID.hasPrefix(appStore))
        }
    }

    func testAloneIsNoConflict() {
        XCTAssertNil(conflict(own: standalone, [(standalone, ownPID)]))
        XCTAssertNil(conflict(own: appStore, []))
    }

    func testSameBuildIsHandedOver() {
        XCTAssertEqual(conflict(own: standalone, [(standalone, ownPID), (standalone, 7)]), .sameBuild(pid: 7))
        XCTAssertEqual(conflict(own: appStore, [(appStore, 7), (appStore, ownPID)]), .sameBuild(pid: 7))
    }

    func testOtherBuildIsNamed() {
        XCTAssertEqual(conflict(own: standalone, [(appStore, 8)]), .otherBuild(bundleID: appStore, pid: 8))
        XCTAssertEqual(conflict(own: appStore, [(appStore, ownPID), (standalone, 9)]), .otherBuild(bundleID: standalone, pid: 9))
    }

    func testSameBuildComesFirst() {
        XCTAssertEqual(conflict(own: appStore, [(standalone, 9), (appStore, 7)]), .sameBuild(pid: 7))
    }

    func testUnrelatedAppsDontCount() {
        XCTAssertNil(conflict(own: standalone, [("us.ipsupport.other", 3), (nil, 4)]))
    }

    func testNoBundleIDChecksNothing() {
        // `swift run`: beside an installed copy on purpose.
        XCTAssertNil(conflict(own: nil, [(standalone, 7), (appStore, 8)]))
        XCTAssertNil(conflict(own: "", [(standalone, 7)]))
    }

    func testATestIDGivesWayToBothBuilds() {
        // build_appstore.sh's BUNDLE_ID: still the same port and models.
        XCTAssertEqual(conflict(own: "us.ipsupport.llmtray.test", [(standalone, 7)]), .otherBuild(bundleID: standalone, pid: 7))
        XCTAssertEqual(conflict(own: "us.ipsupport.llmtray.test", [(appStore, 8)]), .otherBuild(bundleID: appStore, pid: 8))
    }

    func testAppBundleOfAnExecutable() {
        XCTAssertEqual(AppIdentity.appBundle(ofExecutable: "/Applications/LLMTray.app/Contents/MacOS/LLMTray"), "/Applications/LLMTray.app")
        XCTAssertEqual(AppIdentity.appBundle(ofExecutable: "/x/Copy 2.app/Contents/MacOS/LLMTray"), "/x/Copy 2.app")
        XCTAssertNil(AppIdentity.appBundle(ofExecutable: "/Applications/LLMTray.app/Contents/Helpers/llmtray"))
        XCTAssertNil(AppIdentity.appBundle(ofExecutable: "/usr/local/bin/LLMTray"))
        XCTAssertNil(AppIdentity.appBundle(ofExecutable: "/x/Contents/MacOS/LLMTray"))
    }

    func testNothingRunsUnderAnUnknownID() {
        XCTAssertEqual(AppIdentity.runningPIDs(bundleID: "us.ipsupport.llmtray.nothing-\(UUID().uuidString)"), [])
    }

    // MARK: - The build scripts say the same

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testInfoPlistIsTheStandalones() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, standalone)
    }

    func testBuildScriptsWriteTheAppStoreID() throws {
        let buildApp = try String(contentsOf: repo.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        XCTAssertTrue(buildApp.contains("Set :CFBundleIdentifier \(appStore)\""))
        let buildAppStore = try String(contentsOf: repo.appendingPathComponent("scripts/build_appstore.sh"), encoding: .utf8)
        XCTAssertTrue(buildAppStore.contains("BUNDLE_ID=\"${BUNDLE_ID:-\(appStore)}\""))
    }
}
