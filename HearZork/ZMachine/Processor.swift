import Foundation

/// A stack frame for the Z-machine call stack.
struct StackFrame {
    var returnPC: Int
    var locals: [UInt16]
    var stack: [UInt16]
    var storeVariable: UInt8? // where to put the return value
    var argCount: Int
}

/// The Z-machine execution engine.
final class Processor: @unchecked Sendable {
    let memory: Memory
    let header: Header
    let textDecoder: TextDecoder
    let objectTable: ObjectTable
    let dictionary: Dictionary
    let instructionDecoder: InstructionDecoder
    var io: IOSystem

    var pc: Int = 0
    var callStack: [StackFrame] = []
    var currentFrame: StackFrame
    var running = false
    var version: Int { memory.version }

    // Undo state
    private var undoSnapshots: [(dynamic: [UInt8], stack: [StackFrame], frame: StackFrame, pc: Int)] = []

    // Output streams
    private var outputStream3Buffers: [[UInt8]] = [] // nested stream 3 buffers
    private var outputStream1Active = true
    private var outputStream2Active = false

    // Random number generator
    private var rng: RandomNumberGenerator = SystemRandomNumberGenerator()
    private var predictableRNG: LinearCongruentialRNG?

    init(memory: Memory, io: IOSystem) {
        self.memory = memory
        self.header = Header(memory)
        self.textDecoder = TextDecoder(memory: memory)
        self.objectTable = ObjectTable(memory: memory)
        self.dictionary = Dictionary(memory: memory)
        self.instructionDecoder = InstructionDecoder(memory: memory, textDecoder: textDecoder)
        self.io = io
        self.currentFrame = StackFrame(returnPC: 0, locals: [], stack: [], storeVariable: nil, argCount: 0)
    }

    // MARK: - Execution

    func start() async {
        header.configureInterpreter()
        if version <= 5 {
            pc = Int(header.initialPC)
        } else {
            // V6+: call main routine
            let mainAddr = memory.unpackRoutineAddress(header.initialPC)
            callRoutine(mainAddr, args: [], storeVar: nil)
        }
        running = true
        await run()
    }

    func run() async {
        while running {
            let inst = instructionDecoder.decode(at: pc)
            pc = inst.address + inst.length
            await execute(inst)
        }
    }

    // MARK: - Variable access

    func readVariable(_ varNum: UInt8) -> UInt16 {
        switch varNum {
        case 0x00: // stack
            return currentFrame.stack.popLast() ?? 0
        case 0x01...0x0F: // local
            let idx = Int(varNum) - 1
            return idx < currentFrame.locals.count ? currentFrame.locals[idx] : 0
        default: // global
            let addr = Int(header.globalVariablesAddress) + (Int(varNum) - 0x10) * 2
            return memory.readWord(addr)
        }
    }

    func writeVariable(_ varNum: UInt8, value: UInt16) {
        switch varNum {
        case 0x00: // stack
            currentFrame.stack.append(value)
        case 0x01...0x0F: // local
            let idx = Int(varNum) - 1
            if idx < currentFrame.locals.count {
                currentFrame.locals[idx] = value
            }
        default: // global
            let addr = Int(header.globalVariablesAddress) + (Int(varNum) - 0x10) * 2
            memory.writeWord(addr, value: value)
        }
    }

    /// Read a variable without popping the stack (for indirect references).
    func peekVariable(_ varNum: UInt8) -> UInt16 {
        if varNum == 0x00 {
            return currentFrame.stack.last ?? 0
        }
        return readVariable(varNum)
    }

    /// Resolve operands: variables are read, constants passed through.
    func resolveOperand(_ inst: Instruction, _ index: Int) -> UInt16 {
        guard index < inst.operands.count else { return 0 }
        if index < inst.operandTypes.count && inst.operandTypes[index] == .variable {
            return readVariable(UInt8(inst.operands[index]))
        }
        return inst.operands[index]
    }

    func store(_ inst: Instruction, value: UInt16) {
        if let v = inst.storeVariable {
            writeVariable(v, value: value)
        }
    }

    func branch(_ inst: Instruction, condition: Bool) {
        guard let onTrue = inst.branchOnTrue, let offset = inst.branchOffset else { return }
        let shouldBranch = condition == onTrue
        if shouldBranch {
            switch offset {
            case 0: returnValue(0)
            case 1: returnValue(1)
            default: pc = pc - inst.length + inst.length - branchBytes(inst) + offset - 2
                // Actually: branch target = Address after branch data + Offset - 2
                // The offset is relative to the byte after the branch data
                pc = branchTarget(inst, offset: offset)
            }
        }
    }

    private func branchTarget(_ inst: Instruction, offset: Int) -> Int {
        // Branch target = address of first byte after the complete instruction + offset - 2
        return inst.address + inst.length + offset - 2
    }

    private func branchBytes(_ inst: Instruction) -> Int {
        // Not needed with branchTarget approach
        return 0
    }

    // MARK: - Call/Return

    func callRoutine(_ packedOrAddr: Int, args: [UInt16], storeVar: UInt8?) {
        if packedOrAddr == 0 {
            // Call to address 0 returns false
            if let sv = storeVar {
                writeVariable(sv, value: 0)
            }
            return
        }

        let routineAddr = packedOrAddr

        // Save current frame
        callStack.append(currentFrame)

        // Read routine header
        let localCount = Int(memory.readByte(routineAddr))
        var locals: [UInt16]
        var bodyPC: Int

        if version <= 4 {
            // V1-4: locals have initial values
            locals = (0..<localCount).map { i in
                memory.readWord(routineAddr + 1 + i * 2)
            }
            bodyPC = routineAddr + 1 + localCount * 2
        } else {
            // V5+: locals initialized to 0
            locals = [UInt16](repeating: 0, count: localCount)
            bodyPC = routineAddr + 1
        }

        // Copy arguments into locals
        for (i, arg) in args.enumerated() {
            if i < localCount {
                locals[i] = arg
            }
        }

        currentFrame = StackFrame(
            returnPC: pc,
            locals: locals,
            stack: [],
            storeVariable: storeVar,
            argCount: args.count
        )
        pc = bodyPC
    }

    func returnValue(_ value: UInt16) {
        guard let frame = callStack.popLast() else {
            running = false
            return
        }
        let storeVar = currentFrame.storeVariable
        pc = currentFrame.returnPC
        currentFrame = frame
        if let sv = storeVar {
            writeVariable(sv, value: value)
        }
    }

    // MARK: - Signed arithmetic helpers

    func signed(_ v: UInt16) -> Int16 { Int16(bitPattern: v) }
    func unsigned(_ v: Int16) -> UInt16 { UInt16(bitPattern: v) }

    // MARK: - Print helper

    func printString(_ text: String) {
        if !outputStream3Buffers.isEmpty {
            // Output stream 3 is active: capture to buffer
            for ch in text.utf8 {
                outputStream3Buffers[outputStream3Buffers.count - 1].append(ch)
            }
        }
        if outputStream1Active {
            io.print(text)
        }
    }

    // MARK: - Execute instruction

    func execute(_ inst: Instruction) async {
        switch inst.operandCount {
        case .op0:  await execute0OP(inst)
        case .op1:  await execute1OP(inst)
        case .op2:  await execute2OP(inst)
        case .opVar: await executeVAR(inst)
        case .opExt: await executeEXT(inst)
        }
    }

    // MARK: - 0OP Instructions

    func execute0OP(_ inst: Instruction) async {
        switch inst.opcode {
        case 0x00: // rtrue
            returnValue(1)
        case 0x01: // rfalse
            returnValue(0)
        case 0x02: // print
            if let text = inst.textLiteral {
                printString(text)
            }
        case 0x03: // print_ret
            if let text = inst.textLiteral {
                printString(text)
                printString("\n")
            }
            returnValue(1)
        case 0x04: // nop
            break
        case 0x05: // save (V1-3: branch; V4+: store)
            if version <= 3 {
                // TODO: implement save - for now, branch on failure
                branch(inst, condition: false)
            } else {
                store(inst, value: 0) // TODO: implement save
            }
        case 0x06: // restore (V1-3: branch; V4+: store)
            if version <= 3 {
                branch(inst, condition: false)
            } else {
                store(inst, value: 0) // TODO: implement restore
            }
        case 0x07: // restart
            memory.restart()
            header.configureInterpreter()
            callStack = []
            currentFrame = StackFrame(returnPC: 0, locals: [], stack: [], storeVariable: nil, argCount: 0)
            pc = Int(header.initialPC)
        case 0x08: // ret_popped
            let val = readVariable(0x00) // pop stack
            returnValue(val)
        case 0x09: // pop (V1-4) / catch (V5+)
            if version >= 5 {
                // catch: store current frame count
                store(inst, value: UInt16(callStack.count))
            } else {
                _ = readVariable(0x00) // pop and discard
            }
        case 0x0A: // quit
            running = false
        case 0x0B: // new_line
            printString("\n")
        case 0x0C: // show_status (V3)
            showStatusBar()
        case 0x0D: // verify
            branch(inst, condition: verifyChecksum())
        case 0x0F: // piracy
            branch(inst, condition: true) // always pass
        default:
            break
        }
    }

    // MARK: - 1OP Instructions

    func execute1OP(_ inst: Instruction) async {
        let a = resolveOperand(inst, 0)

        switch inst.opcode {
        case 0x00: // jz
            branch(inst, condition: a == 0)
        case 0x01: // get_sibling
            let sib = objectTable.sibling(Int(a))
            store(inst, value: UInt16(sib))
            branch(inst, condition: sib != 0)
        case 0x02: // get_child
            let ch = objectTable.child(Int(a))
            store(inst, value: UInt16(ch))
            branch(inst, condition: ch != 0)
        case 0x03: // get_parent
            let p = objectTable.parent(Int(a))
            store(inst, value: UInt16(p))
        case 0x04: // get_prop_len
            let len = objectTable.getPropertyLength(Int(a))
            store(inst, value: UInt16(len))
        case 0x05: // inc
            let varNum = UInt8(a)
            let val = signed(readVariable(varNum))
            writeVariable(varNum, value: unsigned(val &+ 1))
        case 0x06: // dec
            let varNum = UInt8(a)
            let val = signed(readVariable(varNum))
            writeVariable(varNum, value: unsigned(val &- 1))
        case 0x07: // print_addr
            let (text, _) = textDecoder.decode(at: Int(a))
            printString(text)
        case 0x08: // call_1s (V4+)
            let routineAddr = memory.unpackRoutineAddress(a)
            callRoutine(routineAddr, args: [], storeVar: inst.storeVariable)
        case 0x09: // remove_obj
            objectTable.removeObject(Int(a))
        case 0x0A: // print_obj
            let name = objectTable.shortName(Int(a), decoder: textDecoder)
            printString(name)
        case 0x0B: // ret
            returnValue(a)
        case 0x0C: // jump
            let offset = signed(a)
            pc = pc - inst.length + inst.length + Int(offset) - 2
            // jump offset is relative to the position after the instruction
            pc = inst.address + inst.length + Int(offset) - 2
        case 0x0D: // print_paddr
            let addr = memory.unpackStringAddress(a)
            let (text, _) = textDecoder.decode(at: addr)
            printString(text)
        case 0x0E: // load
            // Load the value of a variable (by indirect reference, not popping stack)
            let val = peekVariable(UInt8(a))
            store(inst, value: val)
        case 0x0F: // not (V1-4) / call_1n (V5+)
            if version >= 5 {
                let routineAddr = memory.unpackRoutineAddress(a)
                callRoutine(routineAddr, args: [], storeVar: nil)
            } else {
                store(inst, value: ~a)
            }
        default:
            break
        }
    }

    // MARK: - 2OP Instructions

    func execute2OP(_ inst: Instruction) async {
        let a = resolveOperand(inst, 0)
        let b = resolveOperand(inst, 1)

        switch inst.opcode {
        case 0x01: // je
            var match = a == b
            if inst.operands.count > 2 {
                let c = resolveOperand(inst, 2)
                match = match || a == c
            }
            if inst.operands.count > 3 {
                let d = resolveOperand(inst, 3)
                match = match || a == d
            }
            branch(inst, condition: match)
        case 0x02: // jl
            branch(inst, condition: signed(a) < signed(b))
        case 0x03: // jg
            branch(inst, condition: signed(a) > signed(b))
        case 0x04: // dec_chk
            let varNum = UInt8(a)
            let val = signed(readVariable(varNum)) &- 1
            writeVariable(varNum, value: unsigned(val))
            branch(inst, condition: val < signed(b))
        case 0x05: // inc_chk
            let varNum = UInt8(a)
            let val = signed(readVariable(varNum)) &+ 1
            writeVariable(varNum, value: unsigned(val))
            branch(inst, condition: val > signed(b))
        case 0x06: // jin (is a child of b?)
            branch(inst, condition: objectTable.parent(Int(a)) == Int(b))
        case 0x07: // test (bitmap)
            branch(inst, condition: (a & b) == b)
        case 0x08: // or
            store(inst, value: a | b)
        case 0x09: // and
            store(inst, value: a & b)
        case 0x0A: // test_attr
            branch(inst, condition: objectTable.testAttribute(Int(a), Int(b)))
        case 0x0B: // set_attr
            objectTable.setAttribute(Int(a), Int(b))
        case 0x0C: // clear_attr
            objectTable.clearAttribute(Int(a), Int(b))
        case 0x0D: // store (indirect)
            writeVariable(UInt8(a), value: b)
        case 0x0E: // insert_obj
            objectTable.insertObject(Int(a), into: Int(b))
        case 0x0F: // loadw
            let addr = Int(a) + Int(signed(b)) * 2
            store(inst, value: memory.readWord(addr))
        case 0x10: // loadb
            let addr = Int(a) + Int(signed(b))
            store(inst, value: UInt16(memory.readByte(addr)))
        case 0x11: // get_prop
            store(inst, value: objectTable.getProperty(Int(a), Int(b)))
        case 0x12: // get_prop_addr
            store(inst, value: UInt16(objectTable.getPropertyAddress(Int(a), Int(b))))
        case 0x13: // get_next_prop
            store(inst, value: UInt16(objectTable.getNextProperty(Int(a), after: Int(b))))
        case 0x14: // add
            store(inst, value: unsigned(signed(a) &+ signed(b)))
        case 0x15: // sub
            store(inst, value: unsigned(signed(a) &- signed(b)))
        case 0x16: // mul
            store(inst, value: unsigned(signed(a) &* signed(b)))
        case 0x17: // div
            guard b != 0 else { return } // TODO: error
            store(inst, value: unsigned(signed(a) / signed(b)))
        case 0x18: // mod
            guard b != 0 else { return }
            store(inst, value: unsigned(signed(a) % signed(b)))
        case 0x19: // call_2s (V4+)
            let routineAddr = memory.unpackRoutineAddress(a)
            callRoutine(routineAddr, args: [b], storeVar: inst.storeVariable)
        case 0x1A: // call_2n (V5+)
            let routineAddr = memory.unpackRoutineAddress(a)
            callRoutine(routineAddr, args: [b], storeVar: nil)
        case 0x1B: // set_colour (V5+)
            io.setColor(foreground: Int(a), background: Int(b))
        case 0x1C: // throw (V5+)
            // Throw: unwind stack to frame b, return value a
            let targetDepth = Int(b)
            while callStack.count > targetDepth {
                _ = callStack.popLast()
            }
            if let frame = callStack.popLast() {
                let storeVar = currentFrame.storeVariable
                pc = currentFrame.returnPC
                currentFrame = frame
                if let sv = storeVar {
                    writeVariable(sv, value: a)
                }
            }
        default:
            break
        }
    }

    // MARK: - VAR Instructions

    func executeVAR(_ inst: Instruction) async {
        switch inst.opcode {
        case 0x00: // call_vs / call
            let packed = resolveOperand(inst, 0)
            let args = (1..<inst.operands.count).map { resolveOperand(inst, $0) }
            let routineAddr = memory.unpackRoutineAddress(packed)
            callRoutine(routineAddr, args: args, storeVar: inst.storeVariable)

        case 0x01: // storew
            let array = resolveOperand(inst, 0)
            let index = resolveOperand(inst, 1)
            let value = resolveOperand(inst, 2)
            let addr = Int(array) + Int(signed(index)) * 2
            memory.writeWord(addr, value: value)

        case 0x02: // storeb
            let array = resolveOperand(inst, 0)
            let index = resolveOperand(inst, 1)
            let value = resolveOperand(inst, 2)
            let addr = Int(array) + Int(signed(index))
            memory.writeByte(addr, value: UInt8(value & 0xFF))

        case 0x03: // put_prop
            let obj = resolveOperand(inst, 0)
            let prop = resolveOperand(inst, 1)
            let value = resolveOperand(inst, 2)
            objectTable.putProperty(Int(obj), Int(prop), value)

        case 0x04: // sread (V1-4) / aread (V5+)
            let textBuf = resolveOperand(inst, 0)
            let parseBuf = inst.operands.count > 1 ? resolveOperand(inst, 1) : 0

            // Show status bar in V1-3
            if version <= 3 {
                showStatusBar()
            }

            let input = await io.readLine(maxChars: Int(memory.readByte(Int(textBuf))))

            // Write input to text buffer
            let inputBytes = Array(input.lowercased().utf8)
            if version <= 4 {
                // V1-4: byte 1 = length, bytes 2+ = characters
                memory.writeByte(Int(textBuf) + 1, value: UInt8(inputBytes.count))
                for (i, byte) in inputBytes.enumerated() {
                    memory.writeByte(Int(textBuf) + 2 + i, value: byte)
                }
            } else {
                // V5+: byte 1 = length, bytes 2+ = characters
                memory.writeByte(Int(textBuf) + 1, value: UInt8(inputBytes.count))
                for (i, byte) in inputBytes.enumerated() {
                    memory.writeByte(Int(textBuf) + 2 + i, value: byte)
                }
            }

            // Tokenize
            if parseBuf != 0 {
                dictionary.tokenize(textBuffer: Int(textBuf), parseBuffer: Int(parseBuf))
            }

            // V5+: store terminating character (13 = enter)
            if version >= 5 {
                store(inst, value: 13)
            }

        case 0x05: // print_char
            let ch = resolveOperand(inst, 0)
            if let char = textDecoder.zsciiToCharacter(ch) {
                printString(String(char))
            }

        case 0x06: // print_num
            let num = signed(resolveOperand(inst, 0))
            printString(String(num))

        case 0x07: // random
            let range = resolveOperand(inst, 0)
            let sRange = signed(range)
            if sRange <= 0 {
                // Seed the RNG
                if sRange == 0 {
                    predictableRNG = nil
                } else {
                    predictableRNG = LinearCongruentialRNG(seed: UInt64(abs(Int(sRange))))
                }
                store(inst, value: 0)
            } else {
                let val: UInt16
                if var prng = predictableRNG {
                    val = UInt16(prng.next(upperBound: UInt32(range))) + 1
                    predictableRNG = prng
                } else {
                    val = UInt16(UInt32.random(in: 1...UInt32(range)))
                }
                store(inst, value: val)
            }

        case 0x08: // push
            let value = resolveOperand(inst, 0)
            currentFrame.stack.append(value)

        case 0x09: // pull
            if version == 6 {
                // V6: pull from user stack
                let val = currentFrame.stack.popLast() ?? 0
                store(inst, value: val)
            } else {
                let varNum = resolveOperand(inst, 0)
                let val = currentFrame.stack.popLast() ?? 0
                writeVariable(UInt8(varNum), value: val)
            }

        case 0x0A: // split_window
            let lines = resolveOperand(inst, 0)
            io.splitWindow(lines: Int(lines))

        case 0x0B: // set_window
            let window = resolveOperand(inst, 0)
            io.setWindow(Int(window))

        case 0x0C: // call_vs2 (V4+)
            let packed = resolveOperand(inst, 0)
            let args = (1..<inst.operands.count).map { resolveOperand(inst, $0) }
            let routineAddr = memory.unpackRoutineAddress(packed)
            callRoutine(routineAddr, args: args, storeVar: inst.storeVariable)

        case 0x0D: // erase_window (V4+)
            let window = resolveOperand(inst, 0)
            io.eraseWindow(Int(signed(window)))

        case 0x0E: // erase_line (V4+)
            break // TODO

        case 0x0F: // set_cursor (V4+)
            let line = resolveOperand(inst, 0)
            let col = resolveOperand(inst, 1)
            io.setCursor(line: Int(line), column: Int(col))

        case 0x10: // get_cursor (V4+)
            break // TODO

        case 0x11: // set_text_style (V4+)
            let style = resolveOperand(inst, 0)
            io.setTextStyle(Int(style))

        case 0x12: // buffer_mode (V4+)
            let flag = resolveOperand(inst, 0)
            io.setBufferMode(flag != 0)

        case 0x13: // output_stream
            let stream = signed(resolveOperand(inst, 0))
            if stream == 3 {
                // Open stream 3 to table
                let table = resolveOperand(inst, 1)
                outputStream3Buffers.append([])
                _ = table // will write to table address when stream closed
            } else if stream == -3 {
                // Close stream 3
                if let buffer = outputStream3Buffers.popLast() {
                    // Write to the table that was specified when opening
                    // For now, just discard - full implementation needs table address tracking
                    _ = buffer
                }
            } else if stream == 1 {
                outputStream1Active = true
            } else if stream == -1 {
                outputStream1Active = false
            } else if stream == 2 {
                outputStream2Active = true
            } else if stream == -2 {
                outputStream2Active = false
            }

        case 0x14: // input_stream
            break // TODO: select input stream

        case 0x15: // sound_effect (V5+)
            if inst.operands.count >= 1 {
                let number = resolveOperand(inst, 0)
                let effect = inst.operands.count > 1 ? resolveOperand(inst, 1) : 0
                let volume = inst.operands.count > 2 ? resolveOperand(inst, 2) : 0
                io.soundEffect(number: Int(number), effect: Int(effect), volume: Int(volume))
            }

        case 0x16: // read_char (V4+)
            let ch = await io.readChar()
            store(inst, value: UInt16(ch))

        case 0x17: // scan_table (V4+)
            let x = resolveOperand(inst, 0)
            let table = resolveOperand(inst, 1)
            let len = resolveOperand(inst, 2)
            let form = inst.operands.count > 3 ? resolveOperand(inst, 3) : 0x82
            let fieldLen = Int(form & 0x7F)
            let isWord = (form & 0x80) != 0

            var found: UInt16 = 0
            for i in 0..<Int(len) {
                let addr = Int(table) + i * fieldLen
                let val = isWord ? memory.readWord(addr) : UInt16(memory.readByte(addr))
                if val == x {
                    found = UInt16(addr)
                    break
                }
            }
            store(inst, value: found)
            branch(inst, condition: found != 0)

        case 0x18: // not (V5+)
            let a = resolveOperand(inst, 0)
            store(inst, value: ~a)

        case 0x19: // call_vn (V5+)
            let packed = resolveOperand(inst, 0)
            let args = (1..<inst.operands.count).map { resolveOperand(inst, $0) }
            let routineAddr = memory.unpackRoutineAddress(packed)
            callRoutine(routineAddr, args: args, storeVar: nil)

        case 0x1A: // call_vn2 (V5+)
            let packed = resolveOperand(inst, 0)
            let args = (1..<inst.operands.count).map { resolveOperand(inst, $0) }
            let routineAddr = memory.unpackRoutineAddress(packed)
            callRoutine(routineAddr, args: args, storeVar: nil)

        case 0x1B: // tokenise (V5+)
            let textBuf = resolveOperand(inst, 0)
            let parseBuf = resolveOperand(inst, 1)
            dictionary.tokenize(textBuffer: Int(textBuf), parseBuffer: Int(parseBuf))

        case 0x1C: // encode_text (V5+)
            break // TODO

        case 0x1D: // copy_table (V5+)
            let first = resolveOperand(inst, 0)
            let second = resolveOperand(inst, 1)
            let size = resolveOperand(inst, 2)
            if second == 0 {
                // Zero the table
                for i in 0..<Int(size) {
                    memory.writeByte(Int(first) + i, value: 0)
                }
            } else {
                let sSize = signed(size)
                let len = Int(abs(sSize))
                if sSize > 0 && Int(second) > Int(first) {
                    // Copy forward (may overlap)
                    for i in stride(from: len - 1, through: 0, by: -1) {
                        memory.writeByte(Int(second) + i, value: memory.readByte(Int(first) + i))
                    }
                } else {
                    for i in 0..<len {
                        memory.writeByte(Int(second) + i, value: memory.readByte(Int(first) + i))
                    }
                }
            }

        case 0x1E: // print_table (V5+)
            let addr = resolveOperand(inst, 0)
            let width = resolveOperand(inst, 1)
            let height = inst.operands.count > 2 ? resolveOperand(inst, 2) : 1
            let skip = inst.operands.count > 3 ? resolveOperand(inst, 3) : 0
            for row in 0..<Int(height) {
                for col in 0..<Int(width) {
                    let ch = memory.readByte(Int(addr) + row * (Int(width) + Int(skip)) + col)
                    if let char = textDecoder.zsciiToCharacter(UInt16(ch)) {
                        printString(String(char))
                    }
                }
                if row < Int(height) - 1 {
                    printString("\n")
                }
            }

        case 0x1F: // check_arg_count (V5+)
            let argNum = resolveOperand(inst, 0)
            branch(inst, condition: Int(argNum) <= currentFrame.argCount)

        default:
            break
        }
    }

    // MARK: - EXT Instructions

    func executeEXT(_ inst: Instruction) async {
        switch inst.opcode {
        case 0x00: // save (V5+)
            // TODO: implement Quetzal save
            store(inst, value: 0)

        case 0x01: // restore (V5+)
            // TODO: implement Quetzal restore
            store(inst, value: 0)

        case 0x02: // log_shift
            let number = resolveOperand(inst, 0)
            let places = signed(resolveOperand(inst, 1))
            if places > 0 {
                store(inst, value: number << UInt16(places))
            } else if places < 0 {
                store(inst, value: number >> UInt16(-places))
            } else {
                store(inst, value: number)
            }

        case 0x03: // art_shift
            let number = signed(resolveOperand(inst, 0))
            let places = signed(resolveOperand(inst, 1))
            if places > 0 {
                store(inst, value: unsigned(number << places))
            } else if places < 0 {
                store(inst, value: unsigned(number >> (-places)))
            } else {
                store(inst, value: unsigned(number))
            }

        case 0x04: // set_font
            let font = resolveOperand(inst, 0)
            // Return previous font (1 = normal, 4 = fixed-pitch)
            store(inst, value: font == 0 ? 0 : 1)

        case 0x09: // save_undo
            let snapshot = (
                dynamic: memory.dynamicSnapshot(),
                stack: callStack,
                frame: currentFrame,
                pc: pc
            )
            undoSnapshots.append(snapshot)
            // Keep at most 10 undo states
            if undoSnapshots.count > 10 {
                undoSnapshots.removeFirst()
            }
            store(inst, value: 1) // success

        case 0x0A: // restore_undo
            if let snapshot = undoSnapshots.popLast() {
                memory.restoreDynamic(snapshot.dynamic)
                callStack = snapshot.stack
                currentFrame = snapshot.frame
                pc = snapshot.pc
                // The restore_undo instruction that was executing stored to a variable;
                // we need to store 2 (success, restored) there
                store(inst, value: 2)
            } else {
                store(inst, value: 0) // failure
            }

        case 0x0B: // print_unicode (V5+)
            let ch = resolveOperand(inst, 0)
            if let scalar = UnicodeScalar(Int(ch)) {
                printString(String(Character(scalar)))
            }

        case 0x0C: // check_unicode (V5+)
            let ch = resolveOperand(inst, 0)
            // Can always print, never read
            store(inst, value: ch <= 0xFFFF ? 1 : 0)

        case 0x13: // set_true_colour (V5+)
            break // stub

        default:
            break
        }
    }

    // MARK: - Status bar (V1-3)

    private func showStatusBar() {
        guard version <= 3 else { return }
        // Get location name from global 0 (object number)
        let locObj = Int(readVariable(0x10)) // global 0
        let locName = locObj > 0 ? objectTable.shortName(locObj, decoder: textDecoder) : ""

        let isTime = (header.flags1 & 0x02) != 0
        let g1 = signed(readVariable(0x11)) // global 1
        let g2 = signed(readVariable(0x12)) // global 2

        let rightSide: String
        if isTime {
            let hour = Int(g1)
            let min = Int(g2)
            rightSide = String(format: "%d:%02d", hour, min)
        } else {
            rightSide = "Score: \(g1)  Turns: \(g2)"
        }

        io.showStatusBar(location: locName, rightSide: rightSide)
    }

    // MARK: - Verify

    private func verifyChecksum() -> Bool {
        let expectedChecksum = header.checksum
        var sum: UInt16 = 0
        let fileLen = min(header.fileLength, memory.size)
        for i in 0x40..<fileLen {
            sum = sum &+ UInt16(memory.readByte(i))
        }
        return sum == expectedChecksum
    }
}

// MARK: - Simple predictable RNG

struct LinearCongruentialRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func next(upperBound: UInt32) -> UInt32 {
        let val = next()
        return UInt32(val >> 33) % upperBound
    }
}
