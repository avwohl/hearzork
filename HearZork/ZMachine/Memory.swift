import Foundation

/// Z-machine memory model: a linear byte array divided into dynamic, static, and high memory regions.
/// All multi-byte values are big-endian.
final class Memory {
    private(set) var bytes: [UInt8]
    let originalBytes: [UInt8]
    let staticBase: Int
    let highBase: Int
    let version: Int

    init(storyData: Data) throws {
        guard storyData.count >= 64 else {
            throw ZError.storyTooSmall
        }
        let raw = [UInt8](storyData)
        self.version = Int(raw[0x00])
        guard (1...8).contains(version), version != 6 else {
            throw ZError.unsupportedVersion(version)
        }
        self.staticBase = Int(raw[0x0E]) << 8 | Int(raw[0x0F])
        self.highBase = Int(raw[0x04]) << 8 | Int(raw[0x05])
        self.bytes = raw
        self.originalBytes = raw
    }

    var size: Int { bytes.count }

    // MARK: - Byte access

    func readByte(_ address: Int) -> UInt8 {
        guard address >= 0 && address < bytes.count else { return 0 }
        return bytes[address]
    }

    func writeByte(_ address: Int, value: UInt8) {
        guard address >= 0 && address < staticBase else { return }
        bytes[address] = value
    }

    // MARK: - Word access (big-endian)

    func readWord(_ address: Int) -> UInt16 {
        let hi = UInt16(readByte(address))
        let lo = UInt16(readByte(address + 1))
        return (hi << 8) | lo
    }

    func writeWord(_ address: Int, value: UInt16) {
        writeByte(address, value: UInt8(value >> 8))
        writeByte(address + 1, value: UInt8(value & 0xFF))
    }

    // MARK: - Packed address decoding

    func unpackRoutineAddress(_ packed: UInt16) -> Int {
        switch version {
        case 1...3: return Int(packed) * 2
        case 4, 5:  return Int(packed) * 4
        case 7:     return Int(packed) * 4 + Int(readWord(0x28)) * 8
        case 8:     return Int(packed) * 8
        default:    return Int(packed) * 2
        }
    }

    func unpackStringAddress(_ packed: UInt16) -> Int {
        switch version {
        case 1...3: return Int(packed) * 2
        case 4, 5:  return Int(packed) * 4
        case 7:     return Int(packed) * 4 + Int(readWord(0x2A)) * 8
        case 8:     return Int(packed) * 8
        default:    return Int(packed) * 2
        }
    }

    // MARK: - Dynamic memory snapshot (for save/undo)

    func dynamicSnapshot() -> [UInt8] {
        Array(bytes[0..<staticBase])
    }

    func restoreDynamic(_ snapshot: [UInt8]) {
        guard snapshot.count == staticBase else { return }
        for i in 0..<staticBase {
            bytes[i] = snapshot[i]
        }
    }

    /// Reset dynamic memory to original state.
    func restart() {
        for i in 0..<staticBase {
            bytes[i] = originalBytes[i]
        }
    }
}

enum ZError: Error, CustomStringConvertible {
    case storyTooSmall
    case unsupportedVersion(Int)
    case invalidAddress(Int)
    case divisionByZero
    case stackUnderflow
    case invalidRoutine(Int)
    case invalidOpcode(Int)
    case quitRequested
    case restartRequested
    case saveRequested
    case restoreRequested

    var description: String {
        switch self {
        case .storyTooSmall: return "Story file is too small (minimum 64 bytes)"
        case .unsupportedVersion(let v): return "Unsupported Z-machine version: \(v)"
        case .invalidAddress(let a): return "Invalid memory address: \(a)"
        case .divisionByZero: return "Division by zero"
        case .stackUnderflow: return "Stack underflow"
        case .invalidRoutine(let a): return "Invalid routine at address: \(a)"
        case .invalidOpcode(let o): return "Invalid opcode: \(o)"
        case .quitRequested: return "Quit requested"
        case .restartRequested: return "Restart requested"
        case .saveRequested: return "Save requested"
        case .restoreRequested: return "Restore requested"
        }
    }
}
