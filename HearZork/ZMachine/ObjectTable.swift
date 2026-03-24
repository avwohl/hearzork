import Foundation

/// Z-machine object table: property defaults, object tree, and per-object property tables.
final class ObjectTable {
    let memory: Memory
    let version: Int
    let tableBase: Int

    // V1-3: 31 default properties (62 bytes), 9 bytes per object
    // V4+:  63 default properties (126 bytes), 14 bytes per object
    private let defaultPropertiesSize: Int
    private let objectEntrySize: Int
    private let maxAttributes: Int
    private let attributeBytes: Int
    private let relationshipSize: Int // 1 byte (V1-3) or 2 bytes (V4+)

    init(memory: Memory) {
        self.memory = memory
        self.version = memory.version
        self.tableBase = Int(memory.readWord(0x0A))
        if version <= 3 {
            defaultPropertiesSize = 62  // 31 words
            objectEntrySize = 9
            maxAttributes = 32
            attributeBytes = 4
            relationshipSize = 1
        } else {
            defaultPropertiesSize = 126 // 63 words
            objectEntrySize = 14
            maxAttributes = 48
            attributeBytes = 6
            relationshipSize = 2
        }
    }

    // MARK: - Property defaults

    func defaultProperty(_ prop: Int) -> UInt16 {
        let addr = tableBase + (prop - 1) * 2
        return memory.readWord(addr)
    }

    // MARK: - Object entry address

    private func objectAddress(_ obj: Int) -> Int {
        tableBase + defaultPropertiesSize + (obj - 1) * objectEntrySize
    }

    // MARK: - Attributes

    func testAttribute(_ obj: Int, _ attr: Int) -> Bool {
        guard obj > 0, attr < maxAttributes else { return false }
        let addr = objectAddress(obj)
        let byteIndex = attr / 8
        let bitIndex = 7 - (attr % 8)
        return (memory.readByte(addr + byteIndex) & (1 << bitIndex)) != 0
    }

    func setAttribute(_ obj: Int, _ attr: Int) {
        guard obj > 0, attr < maxAttributes else { return }
        let addr = objectAddress(obj)
        let byteIndex = attr / 8
        let bitIndex = 7 - (attr % 8)
        let current = memory.readByte(addr + byteIndex)
        memory.writeByte(addr + byteIndex, value: current | (1 << bitIndex))
    }

    func clearAttribute(_ obj: Int, _ attr: Int) {
        guard obj > 0, attr < maxAttributes else { return }
        let addr = objectAddress(obj)
        let byteIndex = attr / 8
        let bitIndex = 7 - (attr % 8)
        let current = memory.readByte(addr + byteIndex)
        memory.writeByte(addr + byteIndex, value: current & ~(1 << bitIndex))
    }

    // MARK: - Relationships

    func parent(_ obj: Int) -> Int {
        guard obj > 0 else { return 0 }
        let addr = objectAddress(obj) + attributeBytes
        return relationshipSize == 1 ? Int(memory.readByte(addr)) : Int(memory.readWord(addr))
    }

    func sibling(_ obj: Int) -> Int {
        guard obj > 0 else { return 0 }
        let addr = objectAddress(obj) + attributeBytes + relationshipSize
        return relationshipSize == 1 ? Int(memory.readByte(addr)) : Int(memory.readWord(addr))
    }

    func child(_ obj: Int) -> Int {
        guard obj > 0 else { return 0 }
        let addr = objectAddress(obj) + attributeBytes + relationshipSize * 2
        return relationshipSize == 1 ? Int(memory.readByte(addr)) : Int(memory.readWord(addr))
    }

    private func setParent(_ obj: Int, _ value: Int) {
        let addr = objectAddress(obj) + attributeBytes
        if relationshipSize == 1 {
            memory.writeByte(addr, value: UInt8(value))
        } else {
            memory.writeWord(addr, value: UInt16(value))
        }
    }

    private func setSibling(_ obj: Int, _ value: Int) {
        let addr = objectAddress(obj) + attributeBytes + relationshipSize
        if relationshipSize == 1 {
            memory.writeByte(addr, value: UInt8(value))
        } else {
            memory.writeWord(addr, value: UInt16(value))
        }
    }

    private func setChild(_ obj: Int, _ value: Int) {
        let addr = objectAddress(obj) + attributeBytes + relationshipSize * 2
        if relationshipSize == 1 {
            memory.writeByte(addr, value: UInt8(value))
        } else {
            memory.writeWord(addr, value: UInt16(value))
        }
    }

    // MARK: - Tree operations

    /// Remove object from its parent's child list.
    func removeObject(_ obj: Int) {
        let p = parent(obj)
        guard p != 0 else { return }

        let firstChild = child(p)
        if firstChild == obj {
            setChild(p, sibling(obj))
        } else {
            var prev = firstChild
            while prev != 0 {
                let sib = sibling(prev)
                if sib == obj {
                    setSibling(prev, sibling(obj))
                    break
                }
                prev = sib
            }
        }
        setParent(obj, 0)
        setSibling(obj, 0)
    }

    /// Insert object as first child of destination.
    func insertObject(_ obj: Int, into dest: Int) {
        removeObject(obj)
        setSibling(obj, child(dest))
        setChild(dest, obj)
        setParent(obj, dest)
    }

    // MARK: - Property table

    func propertyTableAddress(_ obj: Int) -> Int {
        let addr = objectAddress(obj) + attributeBytes + relationshipSize * 3
        return Int(memory.readWord(addr))
    }

    /// Get the short name of an object (from its property table header).
    func shortName(_ obj: Int, decoder: TextDecoder) -> String {
        let ptAddr = propertyTableAddress(obj)
        let textLen = Int(memory.readByte(ptAddr)) // word count
        if textLen == 0 { return "" }
        let (name, _) = decoder.decode(at: ptAddr + 1)
        return name
    }

    /// Get a property value. Returns the default if the object doesn't define it.
    func getProperty(_ obj: Int, _ prop: Int) -> UInt16 {
        guard let (addr, size) = findProperty(obj, prop) else {
            return defaultProperty(prop)
        }
        if size == 1 {
            return UInt16(memory.readByte(addr))
        } else {
            return memory.readWord(addr)
        }
    }

    /// Set a property value.
    func putProperty(_ obj: Int, _ prop: Int, _ value: UInt16) {
        guard let (addr, size) = findProperty(obj, prop) else { return }
        if size == 1 {
            memory.writeByte(addr, value: UInt8(value & 0xFF))
        } else {
            memory.writeWord(addr, value: value)
        }
    }

    /// Get the address of a property's data.
    func getPropertyAddress(_ obj: Int, _ prop: Int) -> Int {
        guard let (addr, _) = findProperty(obj, prop) else { return 0 }
        return addr
    }

    /// Get the length of a property at a given data address.
    func getPropertyLength(_ dataAddr: Int) -> Int {
        if dataAddr == 0 { return 0 }
        let sizeByte = memory.readByte(dataAddr - 1)
        if version <= 3 {
            return Int(sizeByte >> 5) + 1
        } else {
            if (sizeByte & 0x80) != 0 {
                let len = Int(sizeByte & 0x3F)
                return len == 0 ? 64 : len
            } else {
                return (sizeByte & 0x40) != 0 ? 2 : 1
            }
        }
    }

    /// Get the next property number after the given one (0 = get first property).
    func getNextProperty(_ obj: Int, after prop: Int) -> Int {
        let ptAddr = propertyTableAddress(obj)
        let textLen = Int(memory.readByte(ptAddr))
        var addr = ptAddr + 1 + textLen * 2

        if prop == 0 {
            // Return the first property number
            let sizeByte = memory.readByte(addr)
            if sizeByte == 0 { return 0 }
            return propertyNumber(sizeByte)
        }

        // Walk properties until we find the one after prop
        while true {
            let sizeByte = memory.readByte(addr)
            if sizeByte == 0 { return 0 }
            let pn = propertyNumber(sizeByte)
            let (dataStart, dataLen) = propertyDataInfo(addr)
            if pn == prop {
                // Return the next property
                let nextAddr = dataStart + dataLen
                let nextSizeByte = memory.readByte(nextAddr)
                if nextSizeByte == 0 { return 0 }
                return propertyNumber(nextSizeByte)
            }
            addr = dataStart + dataLen
        }
    }

    // MARK: - Private helpers

    /// Find a property, returning (data address, data size) or nil.
    private func findProperty(_ obj: Int, _ prop: Int) -> (Int, Int)? {
        guard obj > 0 else { return nil }
        let ptAddr = propertyTableAddress(obj)
        let textLen = Int(memory.readByte(ptAddr))
        var addr = ptAddr + 1 + textLen * 2

        while true {
            let sizeByte = memory.readByte(addr)
            if sizeByte == 0 { return nil }
            let pn = propertyNumber(sizeByte)
            let (dataAddr, dataLen) = propertyDataInfo(addr)
            if pn == prop {
                return (dataAddr, dataLen)
            }
            if pn < prop { return nil } // properties are in descending order
            addr = dataAddr + dataLen
        }
    }

    private func propertyNumber(_ sizeByte: UInt8) -> Int {
        if version <= 3 {
            return Int(sizeByte & 0x1F)
        } else {
            return Int(sizeByte & 0x3F)
        }
    }

    /// Returns (data start address, data length) given the address of the size byte.
    private func propertyDataInfo(_ sizeAddr: Int) -> (Int, Int) {
        let sizeByte = memory.readByte(sizeAddr)
        if version <= 3 {
            let dataLen = Int(sizeByte >> 5) + 1
            return (sizeAddr + 1, dataLen)
        } else {
            if (sizeByte & 0x80) != 0 {
                let secondByte = memory.readByte(sizeAddr + 1)
                let dataLen = Int(secondByte & 0x3F)
                return (sizeAddr + 2, dataLen == 0 ? 64 : dataLen)
            } else {
                let dataLen = (sizeByte & 0x40) != 0 ? 2 : 1
                return (sizeAddr + 1, dataLen)
            }
        }
    }
}
