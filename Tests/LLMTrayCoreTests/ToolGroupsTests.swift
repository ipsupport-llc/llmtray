import XCTest
@testable import LLMTrayCore

final class ToolGroupsTests: XCTestCase {
    func testMergedPerGroupNotPerField() {
        XCTAssertEqual(ToolGroups.merged(overlay: nil, base: nil), [ToolGroups.documents: .onDemand])
        let base = ToolLoadingMap([ToolGroups.documents: .always])
        XCTAssertEqual(ToolGroups.merged(overlay: ToolLoadingMap([:]), base: base)[ToolGroups.documents], .always,
                       "an overlay that sets no group keeps the base's")
        XCTAssertEqual(ToolGroups.merged(overlay: ToolLoadingMap([ToolGroups.documents: .onDemand]), base: base)[ToolGroups.documents], .onDemand)
    }

    func testDecodesLenientlyAndNeverFailsTheProfile() throws {
        let json = #"{"id": "x", "name": "N", "request": {}, "tools": {"toolLoading": {"documents": "On-Demand", "web": "always", "other": 5}}, "launch": {}}"#
        // A non-string value and an unknown group are skipped one by one.
        let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.tools.toolLoading?.groups, [ToolGroups.documents: .onDemand])
        let notObject = #"{"id": "x", "name": "N", "request": {}, "tools": {"toolLoading": "always"}, "launch": {}}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(notObject.utf8)).tools.toolLoading?.groups, [:])
        let ok = #"{"id": "x", "name": "N", "request": {}, "tools": {"toolLoading": {"documents": "ALWAYS", "nope": "always", "documents2": "maybe"}}, "launch": {}}"#
        let q = try JSONDecoder().decode(Profile.self, from: Data(ok.utf8))
        XCTAssertEqual(q.tools.toolLoading?.groups, [ToolGroups.documents: .always])
        let old = #"{"id": "x", "name": "N", "request": {}, "tools": {}, "launch": {}}"#
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: Data(old.utf8)).tools.toolLoading)
        // Round trip as plain strings.
        let data = try JSONEncoder().encode(ToolLoadingMap([ToolGroups.documents: .onDemand]))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"documents":"onDemand"}"#)
    }

    func testResolvedAndCounted() {
        var overlay = Profile(name: "O")
        overlay.tools.toolLoading = ToolLoadingMap([ToolGroups.documents: .always])
        overlay.request.temperature = 0.5
        XCTAssertEqual(overlay.overrideCount, 2, "one field plus one group")
        overlay.tools.toolLoading = ToolLoadingMap([:])
        XCTAssertEqual(overlay.overrideCount, 1, "an empty map counts no group")
        var base = Profile(id: Profile.defaultID, name: "Default")
        base.tools.toolLoading = ToolLoadingMap([ToolGroups.documents: .always])
        XCTAssertEqual(ProfileResolver.resolve(overlay: overlay, base: base).toolLoading[ToolGroups.documents], .always)
        XCTAssertEqual(ProfileResolver.resolve(overlay: nil, base: Profile(id: Profile.defaultID, name: "D")).toolLoading[ToolGroups.documents], .onDemand)
    }

    func testLoaderOffersTheGroupsWithAPhrase() {
        let schema = ToolGroups.loaderSchema(groups: ToolGroups.all)
        let props = ((schema.definition["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual((props?["group"] as? [String: Any])?["enum"] as? [String], [ToolGroups.documents])
        XCTAssertTrue(schema.description.contains("documents: PDF documents"))
        XCTAssertEqual(ToolGroups.group(ofTool: "make_document")?.name, ToolGroups.documents)
        XCTAssertNil(ToolGroups.group(ofTool: "calculate"))
    }
}
