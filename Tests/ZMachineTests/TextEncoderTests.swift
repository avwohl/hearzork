import XCTest
@testable import HearZork

final class TextEncoderTests: XCTestCase {

    func testEncodeNorthV3() {
        let encoder = TextEncoder(version: 3)
        let encoded = encoder.encodeDictionaryWord("north")

        // "north" in V3 Z-characters:
        // n=19, o=20, r=23, t=25, h=13 -> alphabet A0 positions
        // A0: " abcdefghijklmnopqrstuvwxyz" (index 6 = 'a')
        // n = index 19 (14+5=19? no: a=6, b=7, ... n=19)
        // Actually: space=0, then a=6, b=7, c=8, d=9, e=10, f=11, g=12, h=13, i=14, j=15, k=16, l=17, m=18, n=19, o=20, p=21, q=22, r=23, s=24, t=25, u=26, v=27, w=28, x=29, y=30, z=31
        // Wait - Z-chars 0-5 are special, 6-31 map to A0[6]-A0[31] which are a-z
        // So n = 6 + 13 = 19, o = 6 + 14 = 20, r = 6 + 17 = 23, t = 6 + 19 = 25, h = 6 + 7 = 13
        // Then padded with 5: [19, 20, 23, 25, 13, 5]
        // Packed into 2 words:
        // Word 0: (19 << 10) | (20 << 5) | 23 = 0x4E97 -> no end bit
        // Word 1: (25 << 10) | (13 << 5) | 5  = 0x65A5 -> with end bit = 0xE5A5

        let expected: [UInt8] = [0x4E, 0x97, 0xE5, 0xA5]

        XCTAssertEqual(encoded.count, 4, "V3 encoded word should be 4 bytes")
        // Print actual for debugging
        let hexActual = encoded.map { String(format: "%02X", $0) }.joined(separator: " ")
        let hexExpected = expected.map { String(format: "%02X", $0) }.joined(separator: " ")
        XCTAssertEqual(encoded, expected, "Expected \(hexExpected), got \(hexActual)")
    }

    func testDictionaryLookupRoundtrip() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "/Users/wohl/src/zwalker/games/zcode/zork1.z3"))
        let memory = try Memory(storyData: data)
        let dict = Dictionary(memory: memory)
        let decoder = TextDecoder(memory: memory)

        // Read the first 5 dictionary entries and verify we can decode then look them up
        for i in 0..<min(5, dict.entryCount) {
            let entryAddr = dict.entriesBase + i * dict.entryLength
            let (word, _) = decoder.decode(at: entryAddr)
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let lookupAddr = dict.lookup(trimmed)
                XCTAssertEqual(lookupAddr, entryAddr,
                    "Roundtrip failed for word '\(trimmed)' at entry \(i): lookup returned \(lookupAddr) but expected \(entryAddr)")
            }
        }
    }
}
