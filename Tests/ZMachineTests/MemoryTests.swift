import XCTest
@testable import HearZork

final class MemoryTests: XCTestCase {

    func testHeaderParsing() throws {
        // Minimal V3 story file: 64-byte header
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 3  // version
        data[0x04] = 0x00; data[0x05] = 0x40 // high memory base = 64
        data[0x06] = 0x00; data[0x07] = 0x40 // initial PC = 64
        data[0x0E] = 0x00; data[0x0F] = 0x40 // static memory base = 64

        let memory = try Memory(storyData: data)
        XCTAssertEqual(memory.version, 3)
        XCTAssertEqual(memory.staticBase, 64)
        XCTAssertEqual(memory.highBase, 64)

        let header = Header(memory)
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.initialPC, 0x40)
    }

    func testReadWriteByte() throws {
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 3
        data[0x0E] = 0x00; data[0x0F] = 0x40 // static base = 64

        let memory = try Memory(storyData: data)
        memory.writeByte(0x20, value: 0xAB)
        XCTAssertEqual(memory.readByte(0x20), 0xAB)

        // Writes to static memory should be ignored
        memory.writeByte(0x50, value: 0xCD)
        XCTAssertEqual(memory.readByte(0x50), 0)
    }

    func testReadWriteWord() throws {
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 3
        data[0x0E] = 0x00; data[0x0F] = 0x40

        let memory = try Memory(storyData: data)
        memory.writeWord(0x20, value: 0xABCD)
        XCTAssertEqual(memory.readWord(0x20), 0xABCD)
        XCTAssertEqual(memory.readByte(0x20), 0xAB) // big-endian high byte
        XCTAssertEqual(memory.readByte(0x21), 0xCD) // big-endian low byte
    }

    func testPackedAddresses() throws {
        // V3: packed * 2
        var data3 = Data(repeating: 0, count: 128)
        data3[0x00] = 3; data3[0x0E] = 0x00; data3[0x0F] = 0x40
        let mem3 = try Memory(storyData: data3)
        XCTAssertEqual(mem3.unpackRoutineAddress(0x100), 0x200)

        // V5: packed * 4
        var data5 = Data(repeating: 0, count: 128)
        data5[0x00] = 5; data5[0x0E] = 0x00; data5[0x0F] = 0x40
        let mem5 = try Memory(storyData: data5)
        XCTAssertEqual(mem5.unpackRoutineAddress(0x100), 0x400)

        // V8: packed * 8
        var data8 = Data(repeating: 0, count: 128)
        data8[0x00] = 8; data8[0x0E] = 0x00; data8[0x0F] = 0x40
        let mem8 = try Memory(storyData: data8)
        XCTAssertEqual(mem8.unpackRoutineAddress(0x100), 0x800)
    }

    func testDynamicSnapshot() throws {
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 3; data[0x0E] = 0x00; data[0x0F] = 0x40
        let memory = try Memory(storyData: data)

        memory.writeByte(0x20, value: 0xFF)
        let snapshot = memory.dynamicSnapshot()
        memory.writeByte(0x20, value: 0x00)
        XCTAssertEqual(memory.readByte(0x20), 0x00)

        memory.restoreDynamic(snapshot)
        XCTAssertEqual(memory.readByte(0x20), 0xFF)
    }

    func testRestart() throws {
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 3; data[0x0E] = 0x00; data[0x0F] = 0x40
        let memory = try Memory(storyData: data)

        memory.writeByte(0x20, value: 0xFF)
        XCTAssertEqual(memory.readByte(0x20), 0xFF)

        memory.restart()
        XCTAssertEqual(memory.readByte(0x20), 0x00)
    }

    func testUnsupportedVersion() {
        var data = Data(repeating: 0, count: 128)
        data[0x00] = 6 // V6 not supported
        data[0x0E] = 0x00; data[0x0F] = 0x40
        XCTAssertThrowsError(try Memory(storyData: data))
    }
}
