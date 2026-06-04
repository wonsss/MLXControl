import XCTest
@testable import MLXControl

/// Unit tests for the pure helpers — parsing, validation, unit conversion.
/// (UI / subprocess paths are not unit-tested; logic is isolated here.)
final class HelpersTests: XCTestCase {

    func testHumanSize() {
        XCTAssertEqual(humanSize(5_368_709_120), "5.0 GB")   // 5 GiB
        XCTAssertEqual(humanSize(524_288_000), "500 MB")     // <1 GiB → MB
        XCTAssertEqual(humanSize(nil), "…")
    }

    func testFirstMatch() {
        XCTAssertEqual(
            firstMatch("--model\\s+(\\S+)", in: "mlx_lm.server --model mlx-community/Foo-4bit --host x"),
            "mlx-community/Foo-4bit")
        XCTAssertNil(firstMatch("--model\\s+(\\S+)", in: "no model flag here"))
    }

    func testAllMatches() {
        XCTAssertEqual(allMatches("(\\d+)", "a1 b22 c333"), ["1", "22", "333"])
        XCTAssertEqual(allMatches("(\\d+)", "none"), [])
    }

    /// The exact regex used by deleteModel() to reject path-traversal / malformed IDs.
    func testModelIDValidation() {
        let re = #"^[A-Za-z0-9._\-]+(\/[A-Za-z0-9._\-]+)?$"#
        func valid(_ s: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }
        XCTAssertTrue(valid("mlx-community/Qwen3-32B-4bit"))
        XCTAssertTrue(valid("single-name"))
        XCTAssertFalse(valid("../../etc/passwd"))  // path traversal
        XCTAssertFalse(valid("a/b/c"))             // two slashes
        XCTAssertFalse(valid("name with space"))
    }

    @MainActor
    func testWaitUntilFalseReturnsTrueAfterConditionClears() async {
        var checks = 0
        let cleared = await waitUntilFalse(timeout: 0.2, pollInterval: 0.01) {
            checks += 1
            return checks < 3
        }

        XCTAssertTrue(cleared)
        XCTAssertGreaterThanOrEqual(checks, 3)
    }

    @MainActor
    func testWaitUntilFalseReturnsFalseWhenConditionStaysTrue() async {
        let cleared = await waitUntilFalse(timeout: 0.03, pollInterval: 0.01) {
            true
        }

        XCTAssertFalse(cleared)
    }
}
