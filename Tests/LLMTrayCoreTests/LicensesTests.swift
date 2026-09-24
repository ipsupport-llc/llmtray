import XCTest
@testable import LLMTrayCore

final class LicensesTests: XCTestCase {
    func testMetadata() {
        let expr = PythonPackageLicenses.parseMetadata("Metadata-Version: 2.4\nName: numpy\nVersion: 2.5.3\nLicense-Expression: BSD-3-Clause AND 0BSD\nClassifier: License :: OSI Approved :: MIT License\n\nLong description with Name: fake\n")
        XCTAssertEqual(expr?.name, "numpy")
        XCTAssertEqual(expr?.version, "2.5.3")
        XCTAssertEqual(expr?.license, "BSD-3-Clause AND 0BSD")
        let classifier = PythonPackageLicenses.parseMetadata("Name: tokenizers\nVersion: 0.23.2\nLicense: \nClassifier: License :: OSI Approved :: Apache Software License\n")
        XCTAssertEqual(classifier?.license, "Apache Software License")
        let folded = PythonPackageLicenses.parseMetadata("Name: x\nVersion: 1\nLicense: Copyright (c) Someone\n        more text\n")
        XCTAssertEqual(folded?.license, "Copyright (c) Someone")
        let old = PythonPackageLicenses.parseMetadata("Name: z\nVersion: 1\nDescription: text\n        \n        more\nClassifier: License :: OSI Approved :: MIT License\n")
        XCTAssertEqual(old?.license, "MIT License", "whitespace-only continuation lines don't end the headers")
        XCTAssertNil(PythonPackageLicenses.parseMetadata("Version: 1\n"))
        XCTAssertEqual(PythonPackageLicenses.parseMetadata("Name: crlf\r\nVersion: 1\r\nLicense-Expression: MIT\r\n\r\nbody")?.license, "MIT")
        XCTAssertEqual(PythonPackageLicenses.parseMetadata("Name: y\nVersion: 2\n")?.license, "unknown")
    }

    func testScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dist = root.appendingPathComponent("b_pkg-1.0.dist-info")
        try FileManager.default.createDirectory(at: dist.appendingPathComponent("licenses/sub"), withIntermediateDirectories: true)
        try "Name: B-pkg\nVersion: 1.0\nLicense-Expression: MIT\n".write(to: dist.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b_pkg/vendor"), withIntermediateDirectories: true)
        try "vendored text".write(to: root.appendingPathComponent("b_pkg/vendor/LICENSE.txt"), atomically: true, encoding: .utf8)
        try "b_pkg/__init__.py,sha256=x,1\nb_pkg/vendor/LICENSE.txt,sha256=y,2\nb_pkg/license.py,,\nb_pkg-1.0.dist-info/RECORD,,\n".write(to: dist.appendingPathComponent("RECORD"), atomically: true, encoding: .utf8)
        try "MIT text".write(to: dist.appendingPathComponent("licenses/sub/LICENSE"), atomically: true, encoding: .utf8)
        let bare = root.appendingPathComponent("a-2.dist-info")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "Name: a\nVersion: 2\n".write(to: bare.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
        let entries = PythonPackageLicenses.scan(sitePackages: root)
        XCTAssertEqual(entries.map(\.name), ["a", "B-pkg"])
        XCTAssertTrue(entries[1].text.contains("MIT text"))
        XCTAssertTrue(entries[1].text.contains("--- b_pkg/vendor/LICENSE.txt ---\nvendored text"), entries[1].text)
        XCTAssertTrue(entries[0].text.contains("No license file"))
    }

    func testModelCard() {
        XCTAssertEqual(ModelCardLicense.parse("---\nlicense: apache-2.0\nbase_model:\n- google/gemma\ntags:\n- mlx\n---\n# Model"), "apache-2.0")
        XCTAssertEqual(ModelCardLicense.parse("---\nlicense: other\nlicense_name: nvidia-open-model-license\n---\n"), "nvidia-open-model-license")
        XCTAssertEqual(ModelCardLicense.parse("---\nlicense: \"mit\"\n---"), "mit")
        XCTAssertNil(ModelCardLicense.parse("# No front matter\nlicense: mit"))
        XCTAssertEqual(ModelCardLicense.parse("---\r\nlicense: mit\r\n---\r\n"), "mit")
        XCTAssertEqual(ModelCardLicense.parse("---\nlicense: apache-2.0\nextra:\n  license: other\n---"), "apache-2.0", "nested keys don't count")
        XCTAssertEqual(ModelCardLicense.parse("\u{FEFF}---\nlicense: mit # the usual\n---"), "mit")
        XCTAssertNil(ModelCardLicense.parse("---\ntags: [a]\n---\nlicense: mit"))
    }

    func testCatalogDecodesGeneratedJSON() {
        let json = #"{"groups":[{"id":"app","title":"T","entries":[{"name":"Sparkle","version":"2.10.0","license":"MIT","url":"u","text":"x"},{"name":"S","license":"L","text":"y"}]}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(LicenseCatalog.load(url)?.groups.first?.entries.map(\.name), ["Sparkle", "S"])
    }
}
