import Foundation

/// Decodes Z-character encoded text to Unicode strings.
/// Handles alphabets A0/A1/A2, abbreviations, ZSCII escape sequences,
/// and version-specific shift behavior (permanent in V1-2, temporary in V3+).
final class TextDecoder {
    let memory: Memory
    let version: Int
    private let abbreviationsBase: Int

    // Each alphabet table has 26 entries (indices 0-25).
    // Z-chars 6-31 map to alphabet positions 0-25.
    private let alphabetTable: [[Character]]

    // Default alphabets (26 chars each, no leading space):
    // A0: abcdefghijklmnopqrstuvwxyz
    // A1: ABCDEFGHIJKLMNOPQRSTUVWXYZ
    // A2: [escape][newline]0123456789.,!?_#'"/\-:()
    // Position 0 in A2 is the ZSCII escape marker (handled specially)
    // Position 1 in A2 is newline (handled specially)

    init(memory: Memory) {
        self.memory = memory
        self.version = memory.version
        self.abbreviationsBase = Int(memory.readWord(0x18))

        // Check for custom alphabet table (V5+)
        let alphaAddr = version >= 5 ? Int(memory.readWord(0x34)) : 0
        if alphaAddr != 0 {
            var a0 = [Character](repeating: " ", count: 26)
            var a1 = [Character](repeating: " ", count: 26)
            var a2 = [Character](repeating: " ", count: 26)
            a2[0] = "\0" // escape marker (position 0)
            a2[1] = "\n" // newline (position 1)
            for i in 0..<26 {
                a0[i] = Character(UnicodeScalar(memory.readByte(alphaAddr + i)))
                a1[i] = Character(UnicodeScalar(memory.readByte(alphaAddr + 26 + i)))
                if i >= 2 {
                    a2[i] = Character(UnicodeScalar(memory.readByte(alphaAddr + 52 + i)))
                }
            }
            self.alphabetTable = [a0, a1, a2]
        } else {
            self.alphabetTable = [
                Array("abcdefghijklmnopqrstuvwxyz"),
                Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
                Array("\0\n0123456789.,!?_#'\"/\\-:()")
            ]
        }
    }

    /// Decode a Z-string starting at the given byte address.
    /// Returns the decoded string and the number of bytes consumed.
    func decode(at address: Int) -> (String, Int) {
        var zchars: [UInt8] = []
        var addr = address
        var done = false
        while !done {
            let word = memory.readWord(addr)
            done = (word & 0x8000) != 0
            zchars.append(UInt8((word >> 10) & 0x1F))
            zchars.append(UInt8((word >> 5) & 0x1F))
            zchars.append(UInt8(word & 0x1F))
            addr += 2
        }
        let str = decodeZChars(zchars, allowAbbreviations: true)
        return (str, addr - address)
    }

    /// Decode an array of Z-characters to a string.
    func decodeZChars(_ zchars: [UInt8], allowAbbreviations: Bool = true) -> String {
        var result = ""
        var currentAlphabet = 0
        var lockAlphabet = 0 // for V1-2 permanent shifts
        var i = 0

        while i < zchars.count {
            let zc = zchars[i]
            i += 1

            switch zc {
            case 0:
                result.append(" ")

            case 1 where version == 1:
                result.append("\n")

            case 1 where version >= 2:
                // Abbreviation table 0 (V2) or table 0 (V3+: table = zc-1 = 0)
                if allowAbbreviations && i < zchars.count {
                    let abbrIndex = zchars[i]
                    i += 1
                    let tableIndex = version >= 3 ? Int(zc - 1) * 32 + Int(abbrIndex) : Int(abbrIndex)
                    result.append(decodeAbbreviation(tableIndex))
                }

            case 2 where version >= 3:
                // Abbreviation table 1
                if allowAbbreviations && i < zchars.count {
                    let abbrIndex = zchars[i]
                    i += 1
                    let tableIndex = 32 + Int(abbrIndex)
                    result.append(decodeAbbreviation(tableIndex))
                }

            case 3 where version >= 3:
                // Abbreviation table 2
                if allowAbbreviations && i < zchars.count {
                    let abbrIndex = zchars[i]
                    i += 1
                    let tableIndex = 64 + Int(abbrIndex)
                    result.append(decodeAbbreviation(tableIndex))
                }

            case 2 where version <= 2:
                // V1-2: shift up
                if version == 1 {
                    lockAlphabet = (lockAlphabet + 1) % 3
                    currentAlphabet = lockAlphabet
                } else {
                    currentAlphabet = (currentAlphabet + 1) % 3
                }

            case 3 where version <= 2:
                // V1-2: shift down
                if version == 1 {
                    lockAlphabet = (lockAlphabet + 2) % 3
                    currentAlphabet = lockAlphabet
                } else {
                    currentAlphabet = (currentAlphabet + 2) % 3
                }

            case 4:
                // Shift to A1
                if version <= 2 {
                    lockAlphabet = (lockAlphabet + 1) % 3
                    currentAlphabet = lockAlphabet
                } else {
                    currentAlphabet = 1
                }

            case 5:
                // Shift to A2
                if version <= 2 {
                    lockAlphabet = (lockAlphabet + 2) % 3
                    currentAlphabet = lockAlphabet
                } else {
                    currentAlphabet = 2
                }

            case 6...31:
                // Z-chars 6-31 map to alphabet positions 0-25
                let alphaPos = Int(zc) - 6

                if currentAlphabet == 2 && alphaPos == 0 {
                    // A2 position 0: ZSCII escape sequence
                    // Next two Z-chars form a 10-bit ZSCII code
                    if i + 1 < zchars.count {
                        let hi = UInt16(zchars[i])
                        let lo = UInt16(zchars[i + 1])
                        i += 2
                        let zscii = (hi << 5) | lo
                        if let ch = zsciiToCharacter(zscii) {
                            result.append(ch)
                        }
                    }
                } else if currentAlphabet == 2 && alphaPos == 1 {
                    // A2 position 1: newline
                    result.append("\n")
                } else if alphaPos < alphabetTable[currentAlphabet].count {
                    let ch = alphabetTable[currentAlphabet][alphaPos]
                    if ch != "\0" {
                        result.append(ch)
                    }
                }
                // Reset to locked alphabet after temporary shift (V3+)
                if version >= 3 {
                    currentAlphabet = lockAlphabet
                }

            default:
                if version >= 3 {
                    currentAlphabet = lockAlphabet
                }
            }
        }
        return result
    }

    private func decodeAbbreviation(_ tableIndex: Int) -> String {
        let abbrAddr = abbreviationsBase + tableIndex * 2
        let wordAddr = Int(memory.readWord(abbrAddr)) * 2

        var zchars: [UInt8] = []
        var addr = wordAddr
        var done = false
        while !done {
            let word = memory.readWord(addr)
            done = (word & 0x8000) != 0
            zchars.append(UInt8((word >> 10) & 0x1F))
            zchars.append(UInt8((word >> 5) & 0x1F))
            zchars.append(UInt8(word & 0x1F))
            addr += 2
        }
        return decodeZChars(zchars, allowAbbreviations: false)
    }

    func zsciiToCharacter(_ code: UInt16) -> Character? {
        switch code {
        case 0: return nil
        case 13: return "\n"
        case 32...126: return Character(UnicodeScalar(UInt32(code))!)
        case 155...251:
            // Extended characters -- use default Unicode translation table
            let extTable: [UInt16] = [
                0xE4, 0xF6, 0xFC, 0xC4, 0xD6, 0xDC, 0xDF, 0xBB, 0xAB,
                0xEB, 0xEF, 0xFF, 0xCB, 0xCF, 0xE1, 0xE9, 0xED, 0xF3,
                0xFA, 0xFD, 0xC1, 0xC9, 0xCD, 0xD3, 0xDA, 0xDD, 0xE0,
                0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9,
                0xE2, 0xEA, 0xEE, 0xF4, 0xFB, 0xC2, 0xCA, 0xCE, 0xD4,
                0xDB, 0xE3, 0xF1, 0xF5, 0xC3, 0xD1, 0xD5, 0xE6, 0xC6,
                0xE7, 0xC7, 0xFE, 0xF0, 0xDE, 0xD0, 0xA3, 0x153, 0x152,
                0xA1, 0xBF
            ]
            let idx = Int(code) - 155
            if idx < extTable.count, let scalar = UnicodeScalar(extTable[idx]) {
                return Character(scalar)
            }
            return nil
        default: return nil
        }
    }
}

/// Encodes text to Z-characters for dictionary lookup.
final class TextEncoder {
    let version: Int

    init(version: Int) {
        self.version = version
    }

    /// Encode a word to Z-character bytes for dictionary comparison.
    /// Returns the encoded bytes (4 bytes for V1-3, 6 bytes for V4+).
    func encodeDictionaryWord(_ word: String) -> [UInt8] {
        let maxZChars = version <= 3 ? 6 : 9
        let wordBytes = version <= 3 ? 4 : 6
        let lower = word.lowercased()

        var zchars: [UInt8] = []
        for ch in lower {
            if zchars.count >= maxZChars { break }
            if let zc = charToZChar(ch) {
                zchars.append(contentsOf: zc)
            }
        }

        // Truncate to max Z-chars
        if zchars.count > maxZChars {
            zchars = Array(zchars.prefix(maxZChars))
        }

        // Pad with Z-character 5
        while zchars.count < maxZChars {
            zchars.append(5)
        }

        // Pack into words
        var result: [UInt8] = []
        let wordCount = wordBytes / 2
        for w in 0..<wordCount {
            let base = w * 3
            let z0 = UInt16(zchars[base])
            let z1 = UInt16(zchars[base + 1])
            let z2 = UInt16(zchars[base + 2])
            var packed = (z0 << 10) | (z1 << 5) | z2
            if w == wordCount - 1 {
                packed |= 0x8000 // set end bit on last word
            }
            result.append(UInt8(packed >> 8))
            result.append(UInt8(packed & 0xFF))
        }
        return result
    }

    private func charToZChar(_ ch: Character) -> [UInt8]? {
        // Z-chars 6-31 map to alphabet positions 0-25.
        // A0 positions 0-25: a-z (Z-chars 6-31)
        // A1 positions 0-25: A-Z (need shift 4, then Z-chars 6-31)
        // A2 positions 0-25: escape,newline,0-9,.,etc. (need shift 5, then Z-chars 6-31)

        if ch == " " { return [0] }

        // Check A0 (lowercase letters)
        let a0 = "abcdefghijklmnopqrstuvwxyz"
        if let idx = a0.firstIndex(of: ch) {
            let pos = a0.distance(from: a0.startIndex, to: idx)
            return [UInt8(pos + 6)] // Z-char = position + 6
        }

        // Check A2 for digits and punctuation
        // A2 layout: [0]=escape, [1]=newline, [2]='0', [3]='1', ..., [11]='9',
        //            [12]='.', [13]=',', [14]='!', [15]='?', [16]='_', [17]='#',
        //            [18]='\'', [19]='"', [20]='/', [21]='\\', [22]='-', [23]=':',
        //            [24]='(', [25]=')'
        let a2chars: [(Character, Int)] = [
            ("0", 2), ("1", 3), ("2", 4), ("3", 5), ("4", 6),
            ("5", 7), ("6", 8), ("7", 9), ("8", 10), ("9", 11),
            (".", 12), (",", 13), ("!", 14), ("?", 15), ("_", 16),
            ("#", 17), ("'", 18), ("\"", 19), ("/", 20), ("\\", 21),
            ("-", 22), (":", 23), ("(", 24), (")", 25)
        ]
        for (c, pos) in a2chars {
            if ch == c {
                return [5, UInt8(pos + 6)] // shift to A2, then Z-char = position + 6
            }
        }

        // Fall back to ZSCII escape sequence (A2 shift, then escape at position 0 = Z-char 6)
        if let ascii = ch.asciiValue {
            let code = UInt16(ascii)
            return [5, 6, UInt8(code >> 5), UInt8(code & 0x1F)]
        }
        return nil
    }
}
