import XCTest
@testable import WhoopProtocol

final class WHOOPSpO2DecoderTests: XCTestCase {
    /// Fixed 26-byte fixture. CRC 0xD5A0 was generated independently for bytes 0...23 using
    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) and stored little-endian as A0 D5.
    private let knownFrame: [UInt8] = [
        0xAA, 0x52, 0x34, 0x12,
        0x00, 0xF1, 0x53, 0x65,
        0xFD, 0x25,
        0x34, 0x12,
        0xCD, 0xAB,
        0x55,
        0xEF, 0xBE,
        0x20, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x05,
        0xA0, 0xD5
    ]

    func testKnownFrameParsesCanonicalFields() throws {
        let sample = try WHOOPSpO2Decoder.decode(knownFrame)
        XCTAssertEqual(sample.timestampUnix, 1_700_000_000)
        XCTAssertEqual(sample.rawSpO2, 9_725)
        XCTAssertEqual(sample.spo2Percent, 97.25, accuracy: 0.000_001)
        XCTAssertEqual(sample.opticalRatio1Raw, 0x1234)
        XCTAssertEqual(sample.opticalRatio2Raw, 0xABCD)
        XCTAssertEqual(sample.qualityScore, 85)
        XCTAssertEqual(sample.motionVarianceG, 0.032, accuracy: 0.000_001)
        XCTAssertEqual(sample.headerWordRaw, 0x1234)
        XCTAssertEqual(sample.auxiliaryWordRaw, 0xBEEF)
        XCTAssertEqual(sample.trailingMetadata, [1, 2, 3, 4, 5])
    }

    // Opcode VALUE 82 is unrelated to historical record OFFSET 82 (auxByte82).
    func testOpcodeValue82IsNotASaturationMeasurement() throws {
        XCTAssertEqual(knownFrame[1], 82)
        let sample = try WHOOPSpO2Decoder.decode(knownFrame)
        XCTAssertEqual(sample.spo2Percent, 97.25, accuracy: 0.000_001)
        XCTAssertNotEqual(sample.spo2Percent, Double(knownFrame[1]))
    }

    func testCRCMismatchThrows() {
        var corrupted = knownFrame
        corrupted[10] ^= 0x01
        XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(corrupted)) { error in
            guard case WHOOPSpO2DecoderError.crcMismatch = error else {
                return XCTFail("Expected crcMismatch, got \(error)")
            }
        }
    }

    func testRejectsTruncationSyncOpcodeAndOutOfBoundsSpO2() {
        XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(Array(knownFrame.prefix(25)))) { error in
            XCTAssertEqual(error as? WHOOPSpO2DecoderError,
                           .payloadTruncated(expected: 26, actual: 25))
        }

        var badSync = knownFrame
        badSync[0] = 0xAB
        rewriteCRC(&badSync)
        XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(badSync)) { error in
            XCTAssertEqual(error as? WHOOPSpO2DecoderError,
                           .invalidSync(expected: 0xAA, actual: 0xAB))
        }

        var badOpcode = knownFrame
        badOpcode[1] = 0x51
        rewriteCRC(&badOpcode)
        XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(badOpcode)) { error in
            XCTAssertEqual(error as? WHOOPSpO2DecoderError,
                           .unexpectedOpcode(expected: 0x52, actual: 0x51))
        }

        var impossible = knownFrame
        setUInt16LE(6_999, at: 8, in: &impossible)
        rewriteCRC(&impossible)
        XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(impossible)) { error in
            guard case WHOOPSpO2DecoderError.spo2OutOfBounds(let value) = error else {
                return XCTFail("Expected spo2OutOfBounds, got \(error)")
            }
            XCTAssertEqual(value, 69.99, accuracy: 0.000_001)
        }
    }

    func testQualityFilterUsesInclusiveThresholds() throws {
        let base = try WHOOPSpO2Decoder.decode(knownFrame)
        let acceptedAtBoundary = sample(from: base, quality: 70, motion: 0.05)
        let lowQuality = sample(from: base, quality: 69, motion: 0.01)
        let highMotion = sample(from: base, quality: 100, motion: 0.051)
        let both = sample(from: base, quality: 10, motion: 0.5)
        let result = SpO2QualityFilter.filter([acceptedAtBoundary, lowQuality, highMotion, both])
        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertEqual(result.rejectedCount, 3)
        XCTAssertEqual(result.rejectionCount(for: .lowQuality), 2)
        XCTAssertEqual(result.rejectionCount(for: .excessiveMotion), 2)
    }

    func testAggregatorIsDeterministicAndUsesTenPercentTrimPerTail() throws {
        let values: [Double] = [70, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100]
        let epochs = values.enumerated().map { index, value in
            SpO2SleepEpoch(
                sample: makeSample(timestamp: UInt32(1_700_000_000 + index * 300),
                                   percent: value,
                                   quality: 90,
                                   motion: 0.01),
                isSlowWaveSleep: true
            )
        }
        let first = try SpO2Aggregator.aggregate(epochs)
        let second = try SpO2Aggregator.aggregate(Array(epochs.reversed()))
        XCTAssertEqual(first.spo2Percent, 94.5, accuracy: 0.000_001)
        XCTAssertEqual(first.trimCountPerTail, 1)
        XCTAssertEqual(first.validEpochCount, 12)
        XCTAssertEqual(first, second)
    }

    func testAggregatorRequiresTenValidFiveMinuteSWSEpochs() {
        let epochs = (0..<9).map { index in
            SpO2SleepEpoch(
                sample: makeSample(timestamp: UInt32(index * 300),
                                   percent: 97,
                                   quality: 100,
                                   motion: 0),
                isSlowWaveSleep: true
            )
        }
        XCTAssertThrowsError(try SpO2Aggregator.aggregate(epochs)) { error in
            XCTAssertEqual(error as? SpO2AggregatorError,
                           .insufficientValidEpochs(required: 10, actual: 9))
        }
    }

    func testEveryTruncationAndTrailingBytesAreRejected() {
        for length in 0..<knownFrame.count {
            XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(Array(knownFrame.prefix(length))))
        }
        for extra in [1, 2, 26, 1_024] {
            XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(knownFrame + Array(repeating: 0, count: extra)),
                                 "A single-frame decoder must not accept an unchecked suffix")
        }
    }

    func testEverySingleBitCorruptionIsRejected() {
        for offset in knownFrame.indices {
            for bit in 0..<8 {
                var mutated = knownFrame
                mutated[offset] ^= UInt8(1 << bit)
                XCTAssertThrowsError(try WHOOPSpO2Decoder.decode(mutated), "offset=\(offset), bit=\(bit)")
            }
        }
    }

    func testQualityGateRejectsNonFiniteNegativeAndOutOfRangeConstructedSamples() throws {
        let base = try WHOOPSpO2Decoder.decode(knownFrame)
        for motion in [Double.nan, .infinity, -.infinity, -0.001] {
            XCTAssertEqual(SpO2QualityFilter.filter([sample(from: base, quality: 90, motion: motion)]).acceptedCount, 0)
        }
        XCTAssertEqual(SpO2QualityFilter.filter([sample(from: base, quality: 255, motion: 0)]).acceptedCount, 0)
        // The public initializer/Codable path can bypass the byte decoder entirely.
        for percent in [Double.nan, .infinity, -.infinity, 0, 69.99, 100.01, 98] {
            let forged = WHOOPSpO2Sample(timestampUnix: base.timestampUnix, rawSpO2: base.rawSpO2,
                spo2Percent: percent, opticalRatio1Raw: 0, opticalRatio2Raw: 0, qualityScore: 90,
                motionVarianceG: 0, headerWordRaw: 0, auxiliaryWordRaw: 0, trailingMetadata: [])
            XCTAssertEqual(SpO2QualityFilter.filter([forged]).acceptedCount, 0, "percent=\(percent)")
        }
    }

    func testAggregatorCannotCountRetransmissionsAsTenEpochs() {
        let epoch = SpO2SleepEpoch(sample: makeSample(timestamp: 1_000, percent: 97, quality: 90, motion: 0),
                                  isSlowWaveSleep: true)
        XCTAssertThrowsError(try SpO2Aggregator.aggregate(Array(repeating: epoch, count: 100)))
    }

    func testAggregatorRejectsOverlappingFiveMinuteEpochs() {
        let epochs = (0..<20).map {
            SpO2SleepEpoch(sample: makeSample(timestamp: UInt32(1_000 + $0), percent: 97, quality: 90, motion: 0),
                           isSlowWaveSleep: true)
        }
        XCTAssertThrowsError(try SpO2Aggregator.aggregate(epochs))
    }

    func testAggregatorIdenticalRetransmissionsAreIdempotentAndConflictsFailClosed() throws {
        let epochs = (0..<20).map {
            SpO2SleepEpoch(sample: makeSample(timestamp: UInt32(1_000 + $0 * 300),
                percent: Double(90 + $0 % 10), quality: 90, motion: 0), isSlowWaveSleep: true)
        }
        let expected = try SpO2Aggregator.aggregate(epochs)
        XCTAssertEqual(try SpO2Aggregator.aggregate(epochs + Array(repeating: epochs[0], count: 100)), expected)
        let conflictingStage = SpO2SleepEpoch(sample: epochs[0].sample, isSlowWaveSleep: false)
        XCTAssertThrowsError(try SpO2Aggregator.aggregate(epochs + [conflictingStage]))
    }

    private func makeSample(timestamp: UInt32,
                            percent: Double,
                            quality: UInt8,
                            motion: Double) -> WHOOPSpO2Sample {
        WHOOPSpO2Sample(timestampUnix: timestamp,
                        rawSpO2: UInt16((percent * 100).rounded()),
                        spo2Percent: percent,
                        opticalRatio1Raw: 0,
                        opticalRatio2Raw: 0,
                        qualityScore: quality,
                        motionVarianceG: motion,
                        headerWordRaw: 0,
                        auxiliaryWordRaw: 0,
                        trailingMetadata: [])
    }

    private func sample(from sample: WHOOPSpO2Sample,
                        quality: UInt8,
                        motion: Double) -> WHOOPSpO2Sample {
        WHOOPSpO2Sample(timestampUnix: sample.timestampUnix,
                        rawSpO2: sample.rawSpO2,
                        spo2Percent: sample.spo2Percent,
                        opticalRatio1Raw: sample.opticalRatio1Raw,
                        opticalRatio2Raw: sample.opticalRatio2Raw,
                        qualityScore: quality,
                        motionVarianceG: motion,
                        headerWordRaw: sample.headerWordRaw,
                        auxiliaryWordRaw: sample.auxiliaryWordRaw,
                        trailingMetadata: sample.trailingMetadata)
    }

    private func rewriteCRC(_ frame: inout [UInt8]) {
        let crc = WHOOPSpO2Decoder.crc16CCITTFalse(frame.prefix(24))
        frame[24] = UInt8(crc & 0xFF)
        frame[25] = UInt8((crc >> 8) & 0xFF)
    }

    private func setUInt16LE(_ value: UInt16, at offset: Int, in frame: inout [UInt8]) {
        frame[offset] = UInt8(value & 0xFF)
        frame[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}
