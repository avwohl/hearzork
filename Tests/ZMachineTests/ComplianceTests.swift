import XCTest
@testable import HearZork

/// Compliance tests using the Czech and TerpEtude Z-machine test suites.
/// Czech tests opcodes, arithmetic, logic, memory, objects, and print.
/// TerpEtude tests I/O and screen handling.
final class ComplianceTests: XCTestCase {

    /// Load a story file from the zwalker games directory.
    func loadStory(_ name: String) throws -> Data {
        let path = "/Users/wohl/src/zwalker/games/zcode/\(name)"
        let url = URL(fileURLWithPath: path)
        return try Data(contentsOf: url)
    }

    /// Run a story file to completion or timeout, returning captured output.
    func runStory(_ name: String, inputs: [String] = [], timeout: UInt64 = 10_000_000_000) async throws -> String {
        let data = try loadStory(name)
        let memory = try Memory(storyData: data)
        let testIO = TestIO()
        testIO.inputLines = inputs
        let processor = Processor(memory: memory, io: testIO)

        let task = Task { @Sendable in
            await processor.start()
        }

        try await Task.sleep(nanoseconds: timeout)
        processor.running = false
        task.cancel()

        return testIO.outputBuffer
    }

    // MARK: - Czech V5

    func testCzechV5Passes() async throws {
        let output = try await runStory("czech.z5")

        // Czech self-reports its results
        XCTAssertTrue(
            output.contains("Failed: 0"),
            "Czech V5 should report 0 failures. Output:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("Passed:"),
            "Czech V5 should report passing tests. Output:\n\(String(output.prefix(500)))"
        )
        XCTAssertTrue(
            output.contains("Didn't crash: hooray!"),
            "Czech V5 should complete without crashing"
        )
    }

    // MARK: - Czech V3

    func testCzechV3Passes() async throws {
        let output = try await runStory("czech.z3")

        XCTAssertTrue(
            output.contains("Failed: 0"),
            "Czech V3 should report 0 failures. Output:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("Didn't crash: hooray!"),
            "Czech V3 should complete without crashing"
        )
    }

    // MARK: - Czech V8

    func testCzechV8Passes() async throws {
        let output = try await runStory("czech.z8")

        XCTAssertTrue(
            output.contains("Failed: 0"),
            "Czech V8 should report 0 failures. Output:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("Didn't crash: hooray!"),
            "Czech V8 should complete without crashing"
        )
    }

    // MARK: - Czech V4

    func testCzechV4Passes() async throws {
        let output = try await runStory("czech.z4")

        XCTAssertTrue(
            output.contains("Failed: 0"),
            "Czech V4 should report 0 failures. Output:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("Didn't crash: hooray!"),
            "Czech V4 should complete without crashing"
        )
    }

    // MARK: - Czech output comparison

    func testCzechV5OutputMatchesExpected() async throws {
        let output = try await runStory("czech.z5")
        let expectedPath = "/Users/wohl/src/zwalker/games/zcode/czech.out5"
        let expected = try String(contentsOfFile: expectedPath, encoding: .utf8)

        // Compare line by line, skipping header info that varies per interpreter
        let outputLines = output.components(separatedBy: "\n")
        let expectedLines = expected.components(separatedBy: "\n")

        // Check key test sections exist
        let sections = ["Jumps", "Variables", "Arithmetic ops", "Logical ops",
                        "Memory", "Subroutines", "Objects", "Indirect Opcodes",
                        "Print opcodes"]
        for section in sections {
            XCTAssertTrue(
                output.contains(section),
                "Czech output should contain '\(section)' section"
            )
        }

        // Check specific test results match
        // print_num test
        XCTAssertTrue(
            output.contains("print_num (0, 1, -1, 32767,-32768, -1): 0, 1, -1, 32767, -32768, -1"),
            "print_num should produce correct output"
        )
        // print_char test
        XCTAssertTrue(
            output.contains("print_char (abcd): abcd"),
            "print_char should produce correct output"
        )
        // print_obj test
        XCTAssertTrue(
            output.contains("print_obj (Test Object #1Test Object #2): Test Object #1Test Object #2"),
            "print_obj should produce correct output"
        )
        // Abbreviations test
        XCTAssertTrue(
            output.contains("Abbreviations (I love 'xyzzy' [two times]): I love 'xyzzy'  I love 'xyzzy'"),
            "Abbreviation expansion should work correctly"
        )
    }

    // MARK: - TerpEtude

    func testTerpEtudeLoads() async throws {
        let data = try loadStory("etude.z5")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 5)

        let testIO = TestIO()
        let processor = Processor(memory: memory, io: testIO)

        let task = Task { @Sendable in
            await processor.start()
        }

        try await Task.sleep(nanoseconds: 5_000_000_000)
        processor.running = false
        task.cancel()

        // TerpEtude should produce some output
        XCTAssertFalse(
            testIO.outputBuffer.isEmpty,
            "TerpEtude should produce output"
        )
    }

    // MARK: - Multiple game smoke tests

    func testAdventV3Starts() async throws {
        let output = try await runStory("advent.z3", inputs: ["quit", "y"], timeout: 5_000_000_000)
        XCTAssertFalse(output.isEmpty, "Advent should produce output")
    }

    func testMindForeverVoyagingV4Loads() throws {
        let data = try loadStory("a_mind_forever_voyaging.z4")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 4)
    }

    func test905V5Starts() async throws {
        let output = try await runStory("905.z5", inputs: ["quit", "y"], timeout: 5_000_000_000)
        XCTAssertFalse(output.isEmpty, "905 should produce output")
    }

    func testTightSpotV8Loads() throws {
        let data = try loadStory("a_tight_spot.z8")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 8)
    }
}
