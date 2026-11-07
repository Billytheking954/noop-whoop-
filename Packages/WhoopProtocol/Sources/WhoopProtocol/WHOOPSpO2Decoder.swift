import Foundation

/// One decoded frame under the supplied, UNVERIFIED WHOOP 5.0 summary-frame hypothesis.
/// CRC and synthetic tests establish structural consistency, not hardware or physiological validity.
///
/// This is intentionally separate from `SpO2Sample`, which represents the older raw red/IR ADC
/// historical stream. `WHOOPSpO2Sample` is the decoded 26-byte 0x52 summary-frame contract.
public struct WHOOPSpO2Sample: Codable, Equatable, Sendable {
    public let timestampUnix: UInt32
    public let rawSpO2: UInt16
    public let spo2Percent: Double
    /// Bytes 10...11, retained as an unscaled raw optical-ratio register because the supplied
    /// reverse-engineered contract does not define a physical unit or scale for it.
    public let opticalRatio1Raw: UInt16
    /// Bytes 12...13, retained as an unscaled raw optical-ratio register for the same reason.
    public let opticalRatio2Raw: UInt16
    public let qualityScore: UInt8
    public let motionVarianceG: Double
    /// Bytes 2...3 are retained losslessly until their semantics are proven.
    public let headerWordRaw: UInt16
    /// Bytes 15...16 are currently unnamed in the supplied protocol contract.
    public let auxiliaryWordRaw: UInt16
    /// Bytes 19...23 are retained for future reverse engineering rather than guessed at.
    public let trailingMetadata: [UInt8]

    public init(timestampUnix: UInt32,
                rawSpO2: UInt16,
                spo2Percent: Double,
                opticalRatio1Raw: UInt16,
                opticalRatio2Raw: UInt16,
                qualityScore: UInt8,
                motionVarianceG: Double,
                headerWordRaw: UInt16,
                auxiliaryWordRaw: UInt16,
                trailingMetadata: [UInt8]) {
        self.timestampUnix = timestampUnix
        self.rawSpO2 = rawSpO2
        self.spo2Percent = spo2Percent
        self.opticalRatio1Raw = opticalRatio1Raw
        self.opticalRatio2Raw = opticalRatio2Raw
        self.qualityScore = qualityScore
        self.motionVarianceG = motionVarianceG
        self.headerWordRaw = headerWordRaw
        self.auxiliaryWordRaw = auxiliaryWordRaw
        self.trailingMetadata = trailingMetadata
    }
}

public enum WHOOPSpO2DecoderError: Error, Equatable, Sendable {
    case payloadTruncated(expected: Int, actual: Int)
    case unexpectedLength(expected: Int, actual: Int)
    case invalidSync(expected: UInt8, actual: UInt8)
    case unexpectedOpcode(expected: UInt8, actual: UInt8)
    case crcMismatch(expected: UInt16, actual: UInt16)
    case spo2OutOfBounds(Double)
}

extension WHOOPSpO2DecoderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .payloadTruncated(let expected, let actual):
            return "WHOOP SpO2 frame is truncated: expected \(expected) bytes, got \(actual)."
        case .unexpectedLength(let expected, let actual):
            return "Experimental SpO2 frame length mismatch: expected \(expected) bytes, got \(actual)."
        case .invalidSync(let expected, let actual):
            return String(format: "WHOOP SpO2 sync mismatch: expected 0x%02X, got 0x%02X.", expected, actual)
        case .unexpectedOpcode(let expected, let actual):
            return String(format: "WHOOP SpO2 opcode mismatch: expected 0x%02X, got 0x%02X.", expected, actual)
        case .crcMismatch(let expected, let actual):
            return String(format: "WHOOP SpO2 CRC mismatch: expected 0x%04X, got 0x%04X.", expected, actual)
        case .spo2OutOfBounds(let value):
            return String(format: "WHOOP SpO2 value %.2f%% is outside the protocol gate 70...100%%.", value)
        }
    }
}

/// Research decoder for a supplied 26-byte `NIGHTLY_TELEMETRY_SUMMARY` hypothesis.
/// No paired raw device capture in this repository establishes this as an actual WHOOP contract.
///
/// Assumed layout (not independently validated):
/// - byte 0: 0xAA sync
/// - byte 1: 0x52 command identifier. It is NEVER an SpO2 percentage.
/// - bytes 4...7: UInt32 little-endian timestamp
/// - bytes 8...9: UInt16 little-endian SpO2 x 100
/// - bytes 10...13: two raw UInt16 little-endian optical-ratio registers
/// - byte 14: quality score
/// - bytes 17...18: UInt16 little-endian motion variance x 0.001 g
/// - bytes 24...25: CRC-16/CCITT-FALSE over bytes 0...23, stored little-endian
public enum WHOOPSpO2Decoder {
    public static let frameLength = 26
    public static let syncByte: UInt8 = 0xAA
    public static let nightlyTelemetrySummaryOpcode: UInt8 = 0x52

    public static func decode(_ data: Data) throws -> WHOOPSpO2Sample {
        guard data.count <= frameLength else {
            throw WHOOPSpO2DecoderError.unexpectedLength(expected: frameLength, actual: data.count)
        }
        return try decode(Array(data))
    }

    public static func decode(_ bytes: [UInt8]) throws -> WHOOPSpO2Sample {
        guard bytes.count >= frameLength else {
            throw WHOOPSpO2DecoderError.payloadTruncated(expected: frameLength, actual: bytes.count)
        }

        // One input means exactly one frame. Silently truncating would bless an unchecked suffix.
        guard bytes.count == frameLength else {
            throw WHOOPSpO2DecoderError.unexpectedLength(expected: frameLength, actual: bytes.count)
        }
        let frame = bytes

        guard frame[0] == syncByte else {
            throw WHOOPSpO2DecoderError.invalidSync(expected: syncByte, actual: frame[0])
        }
        guard frame[1] == nightlyTelemetrySummaryOpcode else {
            throw WHOOPSpO2DecoderError.unexpectedOpcode(
                expected: nightlyTelemetrySummaryOpcode,
                actual: frame[1]
            )
        }

        let storedCRC = uint16LE(frame, 24)
        let computedCRC = crc16CCITTFalse(frame.prefix(24))
        guard storedCRC == computedCRC else {
            throw WHOOPSpO2DecoderError.crcMismatch(expected: computedCRC, actual: storedCRC)
        }

        let rawSpO2 = uint16LE(frame, 8)
        let percent = Double(rawSpO2) / 100.0
        guard (70.0...100.0).contains(percent) else {
            throw WHOOPSpO2DecoderError.spo2OutOfBounds(percent)
        }

        return WHOOPSpO2Sample(
            timestampUnix: uint32LE(frame, 4),
            rawSpO2: rawSpO2,
            spo2Percent: percent,
            opticalRatio1Raw: uint16LE(frame, 10),
            opticalRatio2Raw: uint16LE(frame, 12),
            qualityScore: frame[14],
            motionVarianceG: Double(uint16LE(frame, 17)) * 0.001,
            headerWordRaw: uint16LE(frame, 2),
            auxiliaryWordRaw: uint16LE(frame, 15),
            trailingMetadata: Array(frame[19...23])
        )
    }

    /// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, refin=false, refout=false, xorout=0x0000.
    public static func crc16CCITTFalse<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    private static func uint16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
