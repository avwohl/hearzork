import Foundation

/// Parsed view of the 64-byte Z-machine header.
struct Header {
    let memory: Memory

    init(_ memory: Memory) {
        self.memory = memory
    }

    // MARK: - Fixed fields (read from story file)

    var version: Int { Int(memory.readByte(0x00)) }
    var flags1: UInt8 { memory.readByte(0x01) }
    var releaseNumber: UInt16 { memory.readWord(0x02) }
    var highMemoryBase: UInt16 { memory.readWord(0x04) }
    var initialPC: UInt16 { memory.readWord(0x06) }
    var dictionaryAddress: UInt16 { memory.readWord(0x08) }
    var objectTableAddress: UInt16 { memory.readWord(0x0A) }
    var globalVariablesAddress: UInt16 { memory.readWord(0x0C) }
    var staticMemoryBase: UInt16 { memory.readWord(0x0E) }
    var flags2: UInt16 { memory.readWord(0x10) }

    var serialNumber: String {
        let bytes = (0x12...0x17).map { memory.readByte($0) }
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    var abbreviationsTableAddress: UInt16 { memory.readWord(0x18) }
    var fileLength: Int {
        let raw = Int(memory.readWord(0x1A))
        switch version {
        case 1...3: return raw * 2
        case 4...5: return raw * 4
        case 6, 7:  return raw * 4
        case 8:     return raw * 8
        default:    return raw * 2
        }
    }
    var checksum: UInt16 { memory.readWord(0x1C) }

    // V5+ fields
    var alphabetTableAddress: UInt16 { memory.readWord(0x34) }
    var headerExtensionTableAddress: UInt16 { memory.readWord(0x36) }
    var terminatingCharactersTable: UInt16 { memory.readWord(0x2E) }

    // MARK: - Interpreter-set fields

    func configureInterpreter(screenWidth: Int = 80, screenHeight: Int = 25) {
        // Interpreter number: 6 = IBM PC (generic)
        memory.writeByte(0x1E, value: 6)
        // Interpreter version
        memory.writeByte(0x1F, value: UInt8(Character("H").asciiValue ?? 0x48))

        if version >= 4 {
            memory.writeByte(0x20, value: UInt8(min(screenHeight, 255)))
            memory.writeByte(0x21, value: UInt8(min(screenWidth, 255)))
        }
        if version >= 5 {
            memory.writeWord(0x22, value: UInt16(screenWidth))
            memory.writeWord(0x24, value: UInt16(screenHeight))
            memory.writeByte(0x26, value: 1) // font width
            memory.writeByte(0x27, value: 1) // font height
            memory.writeByte(0x2C, value: 2) // default background: black
            memory.writeByte(0x2D, value: 9) // default foreground: white
        }

        // Set capability flags
        var f1 = flags1
        if version <= 3 {
            f1 &= ~0x10 // status line available
            f1 |= 0x20  // screen splitting available
        } else {
            f1 |= 0x10  // fixed-space font available
            if version >= 5 {
                f1 |= 0x01 // colors available
            }
        }
        memory.writeByte(0x01, value: f1)

        // Flags 2: declare undo support for V5+
        if version >= 5 {
            var f2 = memory.readByte(0x10)
            f2 |= 0x10 // undo available
            memory.writeByte(0x10, value: f2)
        }

        // Standard revision 1.1
        memory.writeByte(0x32, value: 1)
        memory.writeByte(0x33, value: 1)
    }
}
