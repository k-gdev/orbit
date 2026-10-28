import Foundation
import Testing
@testable import OrbitCore

/// DDC/CI framing and reply parsing. The reply vectors are the real bytes Kevo's monitors sent to a
/// Get VCP 0x10 on 2026-10-28 (ThinkVision P27u-20: 150 of 100; AOC Q27G4ZD: 100 of 100).
@Suite struct DDCTests {
    /// An independent checksum: XOR of `seed` and every byte.
    private func xor(_ seed: UInt8, _ bytes: [UInt8]) -> UInt8 { bytes.reduce(seed, ^) }

    /// A well-formed Get VCP reply, checksummed from 0x50.
    private func reply(result: UInt8 = 0, code: UInt8 = 0x10, maximum: Int, current: Int) -> [UInt8] {
        let body: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                             UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        return body + [xor(0x50, body)]
    }

    @Test func getRequestFraming() {
        // 6E 51 82 01 10 AC is the textbook "get brightness"; the I2C layer adds the 6E.
        #expect(DDC.getVCPRequest(code: 0x10) == [0x51, 0x82, 0x01, 0x10, 0xAC])
        let contrast = DDC.getVCPRequest(code: 0x12)
        #expect(contrast.prefix(4) == [0x51, 0x82, 0x01, 0x12])
        // The checksum covers the destination address 0x6E too.
        #expect(contrast.last == xor(0x6E, Array(contrast.dropLast())))
        #expect(DDC.chipAddress == 0x37)
    }

    @Test func setRequestFraming() {
        #expect(DDC.setVCPRequest(code: 0x10, value: 50) == [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.setVCPRequest(code: 0x10, value: 150) == [0x51, 0x84, 0x03, 0x10, 0x00, 0x96, 0x3E])
        // Big-endian 16-bit value; out-of-range values are clamped, never wrapped.
        let big = DDC.setVCPRequest(code: 0x10, value: 0x1234)
        #expect(Array(big[4...5]) == [0x12, 0x34])
        #expect(big.last == xor(0x6E, Array(big.dropLast())))
        #expect(Array(DDC.setVCPRequest(code: 0x10, value: -5)[4...5]) == [0x00, 0x00])
        #expect(Array(DDC.setVCPRequest(code: 0x10, value: 70_000)[4...5]) == [0xFF, 0xFF])
    }

    @Test func parsesValidReply() {
        let thinkVision: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x96, 0x56]
        #expect(DDC.parseVCPReply(thinkVision, code: 0x10) == VCPValue(current: 150, maximum: 100))
        let aoc: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]
        #expect(DDC.parseVCPReply(aoc, code: 0x10) == VCPValue(current: 100, maximum: 100))
        #expect(DDC.parseVCPReply(reply(maximum: 255, current: 300), code: 0x10) == VCPValue(current: 300, maximum: 255))
        // Trailing bytes past the frame the length byte describes are ignored.
        #expect(DDC.parseVCPReply(aoc + [0x00, 0x00], code: 0x10) == VCPValue(current: 100, maximum: 100))
    }

    @Test func rejectsBadChecksum() {
        var bytes = reply(maximum: 100, current: 40)
        bytes[10] ^= 0x01
        #expect(DDC.parseVCPReply(bytes, code: 0x10) == nil)
        // A flipped data bit with the old checksum is caught too.
        var flipped = reply(maximum: 100, current: 40)
        flipped[9] ^= 0x04
        #expect(DDC.parseVCPReply(flipped, code: 0x10) == nil)
        // All zeros (what a silent bus reads back) has a wrong checksum and source.
        #expect(DDC.parseVCPReply([UInt8](repeating: 0, count: 11), code: 0x10) == nil)
    }

    @Test func rejectsShortReply() {
        let good = reply(maximum: 100, current: 40)
        for length in 0..<good.count {
            #expect(DDC.parseVCPReply(Array(good.prefix(length)), code: 0x10) == nil)
        }
        // The DDC/CI "null message" a busy display sends: 6E 80 BE.
        #expect(DDC.parseVCPReply([0x6E, 0x80, 0xBE], code: 0x10) == nil)
    }

    @Test func rejectsWrongCode() {
        #expect(DDC.parseVCPReply(reply(code: 0x12, maximum: 100, current: 50), code: 0x10) == nil)
        #expect(DDC.parseVCPReply(reply(code: 0x12, maximum: 100, current: 50), code: 0x12) == VCPValue(current: 50, maximum: 100))
    }

    @Test func rejectsWrongOpcodeSourceLengthAndErrorResult() {
        // Result 01 = unsupported VCP code.
        #expect(DDC.parseVCPReply(reply(result: 0x01, maximum: 100, current: 50), code: 0x10) == nil)
        // Wrong opcode (a capabilities reply, E3), re-checksummed so only the opcode is wrong.
        var opcode = Array(reply(maximum: 100, current: 50).dropLast())
        opcode[2] = 0xE3
        #expect(DDC.parseVCPReply(opcode + [xor(0x50, opcode)], code: 0x10) == nil)
        // Not from the display's address.
        var source = Array(reply(maximum: 100, current: 50).dropLast())
        source[0] = 0x6F
        #expect(DDC.parseVCPReply(source + [xor(0x50, source)], code: 0x10) == nil)
        // A length byte that isn't 0x88 (8 payload bytes).
        var length = Array(reply(maximum: 100, current: 50).dropLast())
        length[1] = 0x87
        #expect(DDC.parseVCPReply(length + [xor(0x50, length)], code: 0x10) == nil)
    }
}

/// Link brightness: proportional moves, clamped.
@Suite struct BrightnessLinkTests {
    private func close(_ a: [String: Double], _ b: [String: Double]) -> Bool {
        a.keys.sorted() == b.keys.sorted() && a.allSatisfy { key, value in abs(value - (b[key] ?? .nan)) < 1e-9 }
    }

    @Test func linkProportional() {
        let start = ["tv-left": 0.5, "tv-right": 0.8, "aoc": 0.2]
        // Halving one halves the others.
        #expect(close(BrightnessLink.values(changing: "tv-left", to: 0.25, current: start),
                      ["tv-left": 0.25, "tv-right": 0.4, "aoc": 0.1]))
        // Up by 20 %.
        #expect(close(BrightnessLink.values(changing: "tv-left", to: 0.6, current: start),
                      ["tv-left": 0.6, "tv-right": 0.96, "aoc": 0.24]))
        // No change, no movement.
        #expect(close(BrightnessLink.values(changing: "aoc", to: 0.2, current: start), start))
        // A display the caller didn't list joins at its new value and moves nobody.
        #expect(close(BrightnessLink.values(changing: "new", to: 0.7, current: start),
                      start.merging(["new": 0.7]) { $1 }))
        // Alone, it just takes the new value.
        #expect(close(BrightnessLink.values(changing: "only", to: 0.3, current: ["only": 0.9]), ["only": 0.3]))
    }

    @Test func linkClamps() {
        let start = ["a": 0.5, "b": 0.8, "c": 0.2, "d": 0.0]
        // Doubling: b would be 1.6; d has no ratio and shifts by +0.5.
        #expect(close(BrightnessLink.values(changing: "a", to: 1.0, current: start),
                      ["a": 1.0, "b": 1.0, "c": 0.4, "d": 0.5]))
        // The moved value itself is clamped first (1.4 → 1, -0.2 → 0).
        #expect(close(BrightnessLink.values(changing: "a", to: 1.4, current: start),
                      ["a": 1.0, "b": 1.0, "c": 0.4, "d": 0.5]))
        #expect(close(BrightnessLink.values(changing: "a", to: -0.2, current: start),
                      ["a": 0.0, "b": 0.0, "c": 0.0, "d": 0.0]))
        // From zero there is no ratio: everything shifts by the same amount.
        #expect(close(BrightnessLink.values(changing: "d", to: 0.3, current: start),
                      ["a": 0.8, "b": 1.0, "c": 0.5, "d": 0.3]))
        // Out-of-range inputs for the others are clamped too.
        #expect(close(BrightnessLink.values(changing: "a", to: 0.5, current: ["a": 0.5, "z": 1.7]), ["a": 0.5, "z": 1.0]))
    }
}
