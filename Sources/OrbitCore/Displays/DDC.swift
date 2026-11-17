import Foundation

/// A VCP feature's value from a DDC/CI "Get VCP Feature" reply: where it is now and the most the display
/// says it accepts. Monitors may report a `current` above `maximum` (Kevo's ThinkVisions reply 150 / 100
/// after their own menu boosted them), so callers must not assume `current <= maximum`.
public struct VCPValue: Equatable, Sendable {
    public var current: Int
    public var maximum: Int

    public init(current: Int, maximum: Int) {
        self.current = current
        self.maximum = maximum
    }
}

/// DDC/CI message framing (VESA DDC/CI 1.1) for the two commands Orbit uses: Get VCP Feature and Set VCP
/// Feature. Pure byte work, no I/O; `DDCService` in the app sends the bytes over `IOAVService` I2C.
///
/// A host → display message on the wire is `6E 51 <0x80|n> <n payload bytes> <checksum>`, where 0x6E is the
/// display's 8-bit write address (7-bit `chipAddress` 0x37), 0x51 the host's source address and the checksum
/// the XOR of every preceding byte *including* 0x6E. The I2C driver adds 0x6E itself, so the requests below
/// start at 0x51: `IOAVServiceWriteI2C(service, chipAddress, request[0], request[1...])` sends one.
///
/// A display → host Get VCP reply is 11 bytes: `6E 88 02 <result> <code> <type> <max hi> <max lo>
/// <cur hi> <cur lo> <checksum>`, checksummed from the virtual host address 0x50.
public enum DDC {
    /// The 7-bit I2C address of a display's DDC/CI endpoint.
    public static let chipAddress: UInt8 = 0x37
    /// The display's 8-bit write address, part of every request checksum.
    public static let destinationAddress: UInt8 = 0x6E
    /// The host's source address: the first byte of every request (the I2C "data address").
    public static let sourceAddress: UInt8 = 0x51
    /// The virtual host address a reply's checksum starts from.
    public static let replyChecksumSeed: UInt8 = 0x50
    /// VCP code for luminance (brightness).
    public static let brightness: UInt8 = 0x10
    /// The length of a Get VCP Feature reply.
    public static let replyLength = 11

    static let getOpcode: UInt8 = 0x01
    static let replyOpcode: UInt8 = 0x02
    static let setOpcode: UInt8 = 0x03

    /// The Get VCP Feature request for `code`: `51 82 01 <code> <checksum>`.
    public static func getVCPRequest(code: UInt8) -> [UInt8] {
        request(payload: [getOpcode, code])
    }

    /// The Set VCP Feature request for `code` = `value` (clamped to 0...0xFFFF, sent big-endian):
    /// `51 84 03 <code> <hi> <lo> <checksum>`.
    public static func setVCPRequest(code: UInt8, value: Int) -> [UInt8] {
        let clamped = UInt16(min(max(value, 0), Int(UInt16.max)))
        return request(payload: [setOpcode, code, UInt8(clamped >> 8), UInt8(clamped & 0xFF)])
    }

    /// The current and maximum value from a Get VCP Feature reply for `code`, or nil when the reply is
    /// short, not from the display (0x6E), not a VCP reply (opcode 0x02, length 8), for another VCP code,
    /// reports an error result (unsupported code), or fails its checksum. A bad reply is never trusted.
    public static func parseVCPReply(_ bytes: [UInt8], code: UInt8) -> VCPValue? {
        // 6E 88 02 rc code type mh ml ch cl chk
        guard bytes.count >= replyLength,
              bytes[0] == destinationAddress,
              bytes[1] == 0x80 | UInt8(replyLength - 3),
              bytes[2] == replyOpcode else { return nil }
        let frame = bytes.prefix(replyLength)
        let checksum = frame.dropLast().reduce(replyChecksumSeed, ^)
        guard checksum == frame[frame.startIndex + replyLength - 1] else { return nil }
        guard bytes[3] == 0x00, bytes[4] == code else { return nil }
        let maximum = Int(bytes[6]) << 8 | Int(bytes[7])
        let current = Int(bytes[8]) << 8 | Int(bytes[9])
        return VCPValue(current: current, maximum: maximum)
    }

    /// `51 <0x80|n> <payload> <checksum>`, the checksum seeded with the destination address.
    private static func request(payload: [UInt8]) -> [UInt8] {
        let body = [sourceAddress, 0x80 | UInt8(payload.count)] + payload
        return body + [body.reduce(destinationAddress, ^)]
    }
}
