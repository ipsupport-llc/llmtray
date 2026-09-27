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
}
