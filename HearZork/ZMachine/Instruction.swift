import Foundation

/// Operand count categories.
enum OperandCount {
    case op0, op1, op2, opVar, opExt
}

/// Operand type.
enum OperandType: UInt8 {
    case largeConstant = 0  // 2 bytes
    case smallConstant = 1  // 1 byte
    case variable = 2       // 1 byte (variable number)
    case omitted = 3
}

/// A decoded Z-machine instruction.
struct Instruction {
    let address: Int
    let opcode: Int
    let operandCount: OperandCount
    let operandTypes: [OperandType]
    let operands: [UInt16]
    let storeVariable: UInt8?
    let branchOnTrue: Bool?
    let branchOffset: Int?
    let textLiteral: String?
    let length: Int // total bytes consumed
}

/// Decodes Z-machine instructions from memory.
final class InstructionDecoder {
    let memory: Memory
    let version: Int
    let textDecoder: TextDecoder

    init(memory: Memory, textDecoder: TextDecoder) {
        self.memory = memory
        self.version = memory.version
        self.textDecoder = textDecoder
    }

    func decode(at pc: Int) -> Instruction {
        var pos = pc
        let firstByte = memory.readByte(pos)
        pos += 1

        let opcode: Int
        let operandCount: OperandCount
        var operandTypes: [OperandType] = []
        var operands: [UInt16] = []

        if firstByte == 0xBE && version >= 5 {
            // Extended form
            let extOpcode = memory.readByte(pos)
            pos += 1
            opcode = Int(extOpcode)
            operandCount = .opExt
            let typesByte = memory.readByte(pos)
            pos += 1
            operandTypes = decodeTypeByte(typesByte)
        } else {
            let form = firstByte >> 6

            switch form {
            case 0b11:
                // Variable form
                let isVar = (firstByte & 0x20) != 0
                opcode = Int(firstByte & 0x1F)
                operandCount = isVar ? .opVar : .op2

                let typesByte = memory.readByte(pos)
                pos += 1
                operandTypes = decodeTypeByte(typesByte)

                // Double-variable form (call_vs2, call_vn2): opcode 12 or 26
                if isVar && (opcode == 12 || opcode == 26) {
                    let typesByte2 = memory.readByte(pos)
                    pos += 1
                    operandTypes += decodeTypeByte(typesByte2)
                }

            case 0b10:
                // Short form
                let typeCode = (firstByte >> 4) & 0x03
                opcode = Int(firstByte & 0x0F)
                if typeCode == 0b11 {
                    operandCount = .op0
                } else {
                    operandCount = .op1
                    operandTypes = [OperandType(rawValue: typeCode)!]
                }

            default:
                // Long form (top 2 bits are 0b00 or 0b01)
                opcode = Int(firstByte & 0x1F)
                operandCount = .op2
                let type1: OperandType = (firstByte & 0x40) != 0 ? .variable : .smallConstant
                let type2: OperandType = (firstByte & 0x20) != 0 ? .variable : .smallConstant
                operandTypes = [type1, type2]
            }
        }

        // Read operand values
        for opType in operandTypes {
            switch opType {
            case .largeConstant:
                operands.append(memory.readWord(pos))
                pos += 2
            case .smallConstant:
                operands.append(UInt16(memory.readByte(pos)))
                pos += 1
            case .variable:
                operands.append(UInt16(memory.readByte(pos)))
                pos += 1
            case .omitted:
                break
            }
        }

        // Remove omitted entries
        let filteredTypes = operandTypes.filter { $0 != .omitted }
        let finalOperands = operands

        // Determine if this instruction has store, branch, or text
        let storeVar: UInt8?
        if isStoreInstruction(opcode: opcode, count: operandCount) {
            storeVar = memory.readByte(pos)
            pos += 1
        } else {
            storeVar = nil
        }

        var branchOnTrue: Bool? = nil
        var branchOffset: Int? = nil
        if isBranchInstruction(opcode: opcode, count: operandCount) {
            let branchByte = memory.readByte(pos)
            pos += 1
            branchOnTrue = (branchByte & 0x80) != 0
            if (branchByte & 0x40) != 0 {
                // 1-byte offset (bits 0-5)
                branchOffset = Int(branchByte & 0x3F)
            } else {
                // 2-byte offset (14-bit signed)
                let secondByte = memory.readByte(pos)
                pos += 1
                var offset = (Int(branchByte & 0x3F) << 8) | Int(secondByte)
                if offset >= 0x2000 {
                    offset -= 0x4000 // sign extend 14-bit
                }
                branchOffset = offset
            }
        }

        var textLiteral: String? = nil
        if isTextInstruction(opcode: opcode, count: operandCount) {
            let (text, textLen) = textDecoder.decode(at: pos)
            textLiteral = text
            pos += textLen
        }

        return Instruction(
            address: pc,
            opcode: opcode,
            operandCount: operandCount,
            operandTypes: filteredTypes,
            operands: finalOperands,
            storeVariable: storeVar,
            branchOnTrue: branchOnTrue,
            branchOffset: branchOffset,
            textLiteral: textLiteral,
            length: pos - pc
        )
    }

    private func decodeTypeByte(_ byte: UInt8) -> [OperandType] {
        var types: [OperandType] = []
        for shift in stride(from: 6, through: 0, by: -2) {
            let code = (byte >> shift) & 0x03
            let opType = OperandType(rawValue: code) ?? .omitted
            if opType == .omitted { break }
            types.append(opType)
        }
        return types
    }

    // MARK: - Instruction metadata
    // Store/branch tables based on Z-Machine Standards Document v1.1.
    // Format in z2js reference: (name, hasStore, hasBranch)

    func isStoreInstruction(opcode: Int, count: OperandCount) -> Bool {
        switch count {
        case .op2:
            // or(8), and(9), loadw(F), loadb(10), get_prop(11),
            // get_prop_addr(12), get_next_prop(13),
            // add(14), sub(15), mul(16), div(17), mod(18), call_2s(19)
            return [0x08, 0x09, 0x0F, 0x10, 0x11, 0x12, 0x13,
                    0x14, 0x15, 0x16, 0x17, 0x18, 0x19].contains(opcode)
        case .op1:
            switch opcode {
            case 0x01, 0x02: return true  // get_sibling, get_child (also branch)
            case 0x03: return true         // get_parent
            case 0x04: return true         // get_prop_len
            case 0x08: return true         // call_1s (V4+)
            case 0x0E: return true         // load
            case 0x0F: return version <= 4 // not (V1-4 store), call_1n (V5+ no store)
            default: return false
            }
        case .op0:
            switch opcode {
            case 0x05: return version == 4  // save: V1-3 branch, V4 store, V5+ is EXT
            case 0x06: return version == 4  // restore: same
            case 0x09: return version >= 5  // catch (V5+) stores frame id
            default: return false
            }
        case .opVar:
            switch opcode {
            case 0x00: return true          // call / call_vs
            case 0x04: return version >= 5  // sread V1-4 no store; aread V5+ stores termchar
            case 0x07: return true          // random
            case 0x0C: return true          // call_vs2 (V4+)
            case 0x16: return true          // read_char (V4+)
            case 0x17: return true          // scan_table (V4+)
            case 0x18: return true          // not (V5+)
            default: return false
            }
        case .opExt:
            return [0x00, 0x01, 0x02, 0x03, 0x04, // save, restore, log_shift, art_shift, set_font
                    0x09, 0x0A,                     // save_undo, restore_undo
                    0x0C,                           // check_unicode
                    0x13, 0x1D].contains(opcode)    // get_wind_prop, buffer_screen
        }
    }

    func isBranchInstruction(opcode: Int, count: OperandCount) -> Bool {
        switch count {
        case .op2:
            // je(1), jl(2), jg(3), dec_chk(4), inc_chk(5), jin(6), test(7), test_attr(A)
            return [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0A].contains(opcode)
        case .op1:
            // jz(0), get_sibling(1), get_child(2)
            return [0x00, 0x01, 0x02].contains(opcode)
        case .op0:
            switch opcode {
            case 0x05: return version <= 3  // save: V1-3 branch
            case 0x06: return version <= 3  // restore: V1-3 branch
            case 0x0D: return true          // verify
            case 0x0F: return true          // piracy
            default: return false
            }
        case .opVar:
            // scan_table(17), check_arg_count(1F)
            return [0x17, 0x1F].contains(opcode)
        case .opExt:
            // picture_data(6), push_stack(18), make_menu(1B)
            return [0x06, 0x18, 0x1B].contains(opcode)
        }
    }

    func isTextInstruction(opcode: Int, count: OperandCount) -> Bool {
        guard count == .op0 else { return false }
        return opcode == 0x02 || opcode == 0x03
        // print(2), print_ret(3)
    }
}
