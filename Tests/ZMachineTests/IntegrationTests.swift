import XCTest
@testable import HearZork

final class IntegrationTests: XCTestCase {

    /// Load a Z-machine story file from the zwalker games directory.
    func loadStory(_ name: String) throws -> Data {
        let path = "/Users/wohl/src/zwalker/games/zcode/\(name)"
        let url = URL(fileURLWithPath: path)
        return try Data(contentsOf: url)
    }

    func testZork1Loads() throws {
        let data = try loadStory("zork1.z3")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 3)

        let header = Header(memory)
        XCTAssertEqual(header.version, 3)
        XCTAssertGreaterThan(header.dictionaryAddress, 0)
        XCTAssertGreaterThan(header.objectTableAddress, 0)
        XCTAssertGreaterThan(header.globalVariablesAddress, 0)
    }

    func testZork1Dictionary() throws {
        let data = try loadStory("zork1.z3")
        let memory = try Memory(storyData: data)
        let dict = Dictionary(memory: memory)
        let decoder = TextDecoder(memory: memory)

        XCTAssertGreaterThan(dict.entryCount, 500, "Zork I should have 600+ dictionary entries")

        // "north" should be in the dictionary
        let northAddr = dict.lookup("north")
        XCTAssertNotEqual(northAddr, 0, "'north' should be in Zork I dictionary")

        // "xyzzy" IS in Zork I (Easter egg reference to Colossal Cave)
        let xyzzyAddr = dict.lookup("xyzzy")
        XCTAssertNotEqual(xyzzyAddr, 0, "'xyzzy' should be in Zork I dictionary")

        // "frobozz" should be an unknown word (truncated to "froboz" in V3)
        let gibberishAddr = dict.lookup("qwxkzj")
        XCTAssertEqual(gibberishAddr, 0, "Gibberish should not be in dictionary")

        // Extract all words for voice recognition
        let words = dict.allWords(decoder: decoder)
        XCTAssertGreaterThan(words.count, 500)
    }

    func testZork1Objects() throws {
        let data = try loadStory("zork1.z3")
        let memory = try Memory(storyData: data)
        let objects = ObjectTable(memory: memory)
        let decoder = TextDecoder(memory: memory)

        // Object 1 should exist and have a name
        let name1 = objects.shortName(1, decoder: decoder)
        XCTAssertFalse(name1.isEmpty, "Object 1 should have a name")

        // Test tree relationships
        let parent1 = objects.parent(1)
        // Object 1 might or might not have a parent, just check it doesn't crash
        _ = parent1
        _ = objects.child(1)
        _ = objects.sibling(1)
    }

    func testZork1InitialOutput() async throws {
        let data = try loadStory("zork1.z3")
        let memory = try Memory(storyData: data)
        let testIO = TestIO()
        testIO.inputLines = ["quit", "y"]
        let processor = Processor(memory: memory, io: testIO)

        // Run with a timeout to avoid hanging
        let task = Task { @Sendable in
            await processor.start()
        }

        // Give it 5 seconds
        try await Task.sleep(nanoseconds: 5_000_000_000)
        processor.running = false
        task.cancel()

        // Zork I should print something about a "white house"
        let output = testIO.outputBuffer.lowercased()
        XCTAssertTrue(
            output.contains("white house") || output.contains("zork"),
            "Zork I initial output should mention 'white house' or 'zork'. Got: \(String(output.prefix(500)))"
        )
    }

    func testCursesV5Loads() throws {
        let data = try loadStory("curses.z5")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 5)

        let header = Header(memory)
        XCTAssertEqual(header.version, 5)
    }

    func testCastleAdventureV8Loads() throws {
        let data = try loadStory("castle_adventure.z8")
        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 8)

        let header = Header(memory)
        XCTAssertEqual(header.version, 8)

        // V8: packed addresses should multiply by 8
        let testPacked: UInt16 = 0x100
        XCTAssertEqual(memory.unpackRoutineAddress(testPacked), 0x800)
    }
}
