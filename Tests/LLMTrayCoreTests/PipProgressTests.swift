import XCTest
@testable import LLMTrayCore

final class PipProgressTests: XCTestCase {
    func testLinesThatSaySomething() {
        XCTAssertEqual(PipProgress.detail(for: "Collecting mflux==0.21.0"), "checking mflux")
        XCTAssertEqual(PipProgress.detail(for: "Collecting mlx<1,>=0.29 (from mflux==0.21.0)"), "checking mlx")
        XCTAssertEqual(PipProgress.detail(for: "  Downloading mlx-0.29.1-cp314-cp314-macosx_15_0_arm64.whl (34.5 MB)"), "downloading mlx (34.5 MB)")
        XCTAssertEqual(PipProgress.detail(for: "  Using cached hf_xet-1.6.0-cp38-abi3-macosx_11_0_arm64.whl (2.6 MB)"), "downloading hf_xet (2.6 MB)")
        XCTAssertEqual(PipProgress.detail(for: "  Downloading sentencepiece-0.2.0.tar.gz (2.6 MB)"), "downloading sentencepiece (2.6 MB)")
        XCTAssertEqual(PipProgress.detail(for: "  Building wheel for antlr4-python3-runtime (pyproject.toml): started"), "building antlr4-python3-runtime")
        XCTAssertEqual(PipProgress.detail(for: "Installing collected packages: mlx, numpy, mflux"), "installing 3 packages")
        // An archive by URL (mlx-audio at a commit) names no package.
        XCTAssertEqual(PipProgress.detail(for: "  Downloading ab0b648b2ce6ad261e8bb3203e08b34680eec471.tar.gz (14.3 MB)"), "downloading (14.3 MB)")
        XCTAssertEqual(PipProgress.detail(for: "  Resuming download mlx-0.29.1-cp314-cp314-macosx_15_0_arm64.whl (12.0 MB/34.5 MB)"), "downloading mlx (34.5 MB)")
    }

    func testLinesThatDont() {
        XCTAssertNil(PipProgress.detail(for: "  Downloading click-8.5.0-py3-none-any.whl.metadata (2.6 kB)"))
        XCTAssertNil(PipProgress.detail(for: "Requirement already satisfied: numpy in ./v/lib/python3.14/site-packages"))
        XCTAssertNil(PipProgress.detail(for: ""))
        XCTAssertNil(PipProgress.detail(for: "Successfully installed mflux-0.21.0"))
    }
}
