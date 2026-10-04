import XCTest
@testable import LLMTrayCore

/// The trust barrier with a fake project tool: its kind is all it takes.
final class ToolTrustTests: XCTestCase {
    let search = (id: "1", kind: ToolTrust.Kind.project)       // a fake search_project_files
    let web = (id: "2", kind: ToolTrust.Kind.guarded)          // web_search
    let image = (id: "3", kind: ToolTrust.Kind.guarded)        // generate_image
    let calc = (id: "4", kind: ToolTrust.Kind.ordinary)        // calculate

    func testBatchWithProjectCallRefusesGuardedUpFront() {
        XCTAssertEqual(ToolTrust.refusedUpFront([search, web, image, calc], projectTextThisTurn: false), ["2", "3"])
        // The order in the batch doesn't matter: decided before any runs.
        XCTAssertEqual(ToolTrust.refusedUpFront([image, calc, search], projectTextThisTurn: false), ["3"])
    }

    func testWithoutProjectNothingRefused() {
        XCTAssertEqual(ToolTrust.refusedUpFront([web, image, calc], projectTextThisTurn: false), [])
        XCTAssertTrue(ToolTrust.allowsGuarded(projectTextThisTurn: false))
    }

    func testAfterProjectTextGuardedStayRefused() {
        XCTAssertEqual(ToolTrust.refusedUpFront([web, calc], projectTextThisTurn: true), ["2"])
        XCTAssertFalse(ToolTrust.allowsGuarded(projectTextThisTurn: true))
        XCTAssertEqual(ToolTrust.refusedUpFront([search, calc], projectTextThisTurn: true), [], "project and ordinary tools still run")
    }

    func testAnUnchangedReReadBringsNothingNew() {
        let listing = "Folder ~/Downloads: 2 items.\na.dmg  1 MB\nb.zip  2 MB"
        // The listing the confirmed plan came from, read again: no new text.
        XCTAssertFalse(ToolTrust.readBringsNewText(listing, resultsBeforeThisTurn: [listing, "other"]))
        // Anything else -- a changed folder, another one, a first read -- does.
        XCTAssertTrue(ToolTrust.readBringsNewText(listing + "\nc.pdf  3 KB", resultsBeforeThisTurn: [listing]))
        XCTAssertTrue(ToolTrust.readBringsNewText(listing, resultsBeforeThisTurn: []))
        // And the barrier itself is unchanged: a read in the turn keeps changes off.
        var state = ToolTrust.TurnState()
        state.record(.folderRead)
        XCTAssertFalse(ToolTrust.allowsChange(state))
    }
}
