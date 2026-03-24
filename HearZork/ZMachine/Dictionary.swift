import Foundation

/// Z-machine dictionary: word separator list, encoded dictionary entries, and tokenization.
final class Dictionary {
    let memory: Memory
    let version: Int
    let dictionaryBase: Int
    let separators: [UInt8]
    let entryLength: Int
    let entryCount: Int
    let entriesBase: Int
    let encodedWordLength: Int // 4 bytes (V1-3) or 6 bytes (V4+)

    init(memory: Memory) {
        self.memory = memory
        self.version = memory.version
        self.dictionaryBase = Int(memory.readWord(0x08))

        let sepCount = Int(memory.readByte(dictionaryBase))
        var seps: [UInt8] = []
        for i in 0..<sepCount {
            seps.append(memory.readByte(dictionaryBase + 1 + i))
        }
        self.separators = seps

        let metaBase = dictionaryBase + 1 + sepCount
        self.entryLength = Int(memory.readByte(metaBase))
        let rawCount = Int16(bitPattern: memory.readWord(metaBase + 1))
        self.entryCount = Int(abs(rawCount))
        self.entriesBase = metaBase + 3
        self.encodedWordLength = version <= 3 ? 4 : 6
    }

    /// Look up a word in the dictionary. Returns the byte address of the entry, or 0 if not found.
    func lookup(_ word: String) -> Int {
        let encoder = TextEncoder(version: version)
        let encoded = encoder.encodeDictionaryWord(word)

        // Binary search
        var lo = 0
        var hi = entryCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let entryAddr = entriesBase + mid * entryLength
            let cmp = compareEncoded(encoded, at: entryAddr)
            if cmp == 0 {
                return entryAddr
            } else if cmp < 0 {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return 0
    }

    /// Compare encoded bytes against the entry at the given address.
    /// Returns -1, 0, or 1.
    private func compareEncoded(_ encoded: [UInt8], at entryAddr: Int) -> Int {
        for i in 0..<encodedWordLength {
            let a = encoded[i]
            let b = memory.readByte(entryAddr + i)
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }

    /// Tokenize input text into the parse buffer.
    /// textBuffer starts at the given address:
    ///   V1-4: byte 0 = max chars, byte 1 = actual char count, bytes 2+ = text (no terminator)
    ///   V5+:  byte 0 = max chars, byte 1 = actual char count, bytes 2+ = text (no terminator)
    /// parseBuffer:
    ///   byte 0 = max words, byte 1 = actual word count (written by us)
    ///   then 4-byte entries: word address (2), text length (1), text position (1)
    func tokenize(textBuffer: Int, parseBuffer: Int) {
        let textStart: Int
        let textLength: Int

        if version <= 4 {
            textLength = Int(memory.readByte(textBuffer + 1))
            textStart = textBuffer + 1
        } else {
            textLength = Int(memory.readByte(textBuffer + 1))
            textStart = textBuffer + 2
        }

        let maxWords = Int(memory.readByte(parseBuffer))
        var wordCount = 0
        var parseAddr = parseBuffer + 2

        // Extract the raw text
        var text: [UInt8] = []
        for i in 0..<textLength {
            text.append(memory.readByte(textStart + i))
        }

        var pos = 0
        while pos < text.count && wordCount < maxWords {
            // Skip spaces
            if text[pos] == 0x20 {
                pos += 1
                continue
            }

            // Check if it's a separator
            if separators.contains(text[pos]) {
                let wordStr = String(UnicodeScalar(text[pos]))
                let dictAddr = lookup(wordStr)
                memory.writeWord(parseAddr, value: UInt16(dictAddr))
                memory.writeByte(parseAddr + 2, value: 1)
                memory.writeByte(parseAddr + 3, value: UInt8(pos + (version <= 4 ? 1 : 2)))
                parseAddr += 4
                wordCount += 1
                pos += 1
                continue
            }

            // Collect a word
            let wordStart = pos
            while pos < text.count && text[pos] != 0x20 && !separators.contains(text[pos]) {
                pos += 1
            }
            let wordBytes = Array(text[wordStart..<pos])
            let wordStr = String(wordBytes.map { Character(UnicodeScalar($0)) })
            let dictAddr = lookup(wordStr)
            memory.writeWord(parseAddr, value: UInt16(dictAddr))
            memory.writeByte(parseAddr + 2, value: UInt8(pos - wordStart))
            memory.writeByte(parseAddr + 3, value: UInt8(wordStart + (version <= 4 ? 1 : 2)))
            parseAddr += 4
            wordCount += 1
        }

        memory.writeByte(parseBuffer + 1, value: UInt8(wordCount))
    }

    /// Extract all dictionary words as strings (for voice recognition vocabulary).
    /// Dictionary entries use Z-character encoding but abbreviation Z-chars (1-3)
    /// should NOT be expanded -- they're raw encoded text.
    func allWords(decoder: TextDecoder) -> [String] {
        var words: [String] = []
        for i in 0..<entryCount {
            let addr = entriesBase + i * entryLength
            // Read the encoded Z-chars from the entry (4 bytes for V1-3, 6 bytes for V4+)
            var zchars: [UInt8] = []
            let wordCount = encodedWordLength / 2
            for w in 0..<wordCount {
                let word = decoder.memory.readWord(addr + w * 2)
                zchars.append(UInt8((word >> 10) & 0x1F))
                zchars.append(UInt8((word >> 5) & 0x1F))
                zchars.append(UInt8(word & 0x1F))
            }
            // Decode without abbreviation expansion
            let word = decoder.decodeZChars(zchars, allowAbbreviations: false)
            words.append(word.trimmingCharacters(in: .whitespaces))
        }
        return words
    }
}
