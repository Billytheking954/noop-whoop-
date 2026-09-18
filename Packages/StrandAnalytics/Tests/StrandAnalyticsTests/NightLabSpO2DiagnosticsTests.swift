import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabSpO2DiagnosticsTests: XCTestCase {
    private let windowStart = 1_700_000_010
    private let windowDuration = 8 * 60 * 60

    func testCompleteNightIsDeterministicWhenFramesAreReordered() throws {
        let rows = completeNightRows()
        let first = NightLabSpO2Diagnostics.analyze(
            rows: rows,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )
        let reversed = NightLabSpO2Diagnostics.analyze(
            rows: Array(rows.reversed()),
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertNotNil(first.aggregate)
        XCTAssertEqual(first.aggregate, reversed.aggregate)
        XCTAssertEqual(first.frameCoverageFraction, 1)
    }

    func testSeventyFivePercentCoverageWithTwoHourHoleFailsClosed() throws {
        let rows = completeNightRows().enumerated().compactMap { index, row in
            (36..<60).contains(index) ? nil : row
        }
        let result = NightLabSpO2Diagnostics.analyze(
            rows: rows,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertEqual(result.frameCoverageFraction, 0.75, accuracy: 0.000_001)
        XCTAssertNil(result.aggregate, "incomplete whole-night evidence must not emit a plausible value")
        XCTAssertTrue(result.aggregationError?.contains("whole-night") == true)
    }

    func testHighCoverageWithLargeInternalGapFailsClosed() throws {
        let rows = completeNightRows().enumerated().compactMap { index, row in
            (36..<42).contains(index) ? nil : row
        }
        let result = NightLabSpO2Diagnostics.analyze(
            rows: rows,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertGreaterThan(result.frameCoverageFraction, 0.90)
        XCTAssertNil(result.aggregate, "high total coverage must not hide a long internal hole")
        XCTAssertTrue(result.aggregationError?.contains("frame gap") == true)
    }

    func testIdenticalDuplicateFramesCannotInflateCoverage() throws {
        let one = frame(timestamp: windowStart)
        let result = NightLabSpO2Diagnostics.analyze(
            rows: Array(repeating: one, count: 20),
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertEqual(result.frameCoverageFraction, 1.0 / 96.0, accuracy: 0.000_001)
        XCTAssertNil(result.aggregate)
    }

    func testConflictingDuplicateTimestampFailsClosed() throws {
        var rows = completeNightRows()
        rows.append(frame(timestamp: windowStart, percentHundredths: 9_400))
        let result = NightLabSpO2Diagnostics.analyze(
            rows: rows,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertNil(result.aggregate)
        XCTAssertTrue(result.aggregationError?.contains("conflicting frames") == true)
    }

    func testSamplesAtOrBeyondHalfOpenEndCannotChangeAggregate() throws {
        let rows = completeNightRows()
        let original = NightLabSpO2Diagnostics.analyze(
            rows: rows,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )
        let outside = (0..<20).map {
            frame(timestamp: windowStart + windowDuration + ($0 * 300), percentHundredths: 7_000)
        }
        let withOutside = NightLabSpO2Diagnostics.analyze(
            rows: rows + outside,
            windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration,
            baseline: deepBaseline()
        )

        XCTAssertEqual(original.aggregate, withOutside.aggregate)
        XCTAssertEqual(original.frameCoverageFraction, withOutside.frameCoverageFraction)
    }

    func testClusteredDistinctTimestampsCannotManufactureWholeNightCoverage() {
        // 96 distinct starts and no start-gap >900 seconds previously passed as 100% coverage,
        // although only about one third of the night is represented by non-overlapping intervals.
        let rows = (0..<32).flatMap { group in
            (0..<3).map { frame(timestamp: windowStart + group * 900 + $0) }
        }
        let result = analyze(rows)
        XCTAssertLessThan(result.frameCoverageFraction, 0.40)
        XCTAssertNil(result.aggregate)
    }

    func testRejectedQualityCannotFillAnOtherwiseMissingNight() {
        let rows = (0..<96).map {
            frame(timestamp: windowStart + $0 * 300, quality: $0 < 10 ? 90 : 0)
        }
        XCTAssertNil(analyze(rows).aggregate, "Ten good epochs do not validate a night of rejected evidence")
    }

    func testMissingBeginningOrEndFailsClosedDespiteHighCoverage() {
        let rows = completeNightRows()
        XCTAssertNil(analyze(Array(rows.dropFirst(2))).aggregate)
        XCTAssertNil(analyze(Array(rows.dropLast(2))).aggregate)
    }

    func testMismatchedAndOverlappingBaselineCannotManufactureSlowWaveSleep() {
        let rows = completeNightRows()
        XCTAssertNil(analyze(rows, baseline: deepBaseline(start: windowStart - 300)).aggregate)
        let repeated = (0..<96).flatMap { index in
            Array(repeating: SleepStagerV2BaselineEpoch(startUnix: windowStart + index * 300,
                endUnix: windowStart + index * 300 + 30, stage: .deep), count: 10)
        }
        XCTAssertNil(analyze(rows, baseline: deepBaseline(epochsOverride: repeated)).aggregate,
                     "Ten copies of 30 seconds must not count as 300 seconds of deep sleep")
    }

    func testBackfillCompletionThenEvidenceRemovalRecomputesAvailability() {
        let complete = completeNightRows()
        XCTAssertNil(analyze(Array(complete.prefix(10))).aggregate)
        XCTAssertNotNil(analyze(complete).aggregate)
        XCTAssertNil(analyze(Array(complete.prefix(10))).aggregate)
        XCTAssertNil(analyze([]).aggregate)
    }

    func testMalformedHexAndOversizedFrameCannotReachAggregation() {
        let valid = frame(timestamp: windowStart)
        let malformed = ["", "0", "gg", valid.hex + "00", "+a" + String(valid.hex.dropFirst(2)),
                         String(repeating: "00", count: 1_000)]
        for hex in malformed {
            let result = analyze([NightLabSpO2FrameRow(hex: hex)])
            XCTAssertEqual(result.decodedFrameCount, 0, "hex length=\(hex.count)")
            XCTAssertEqual(result.decodeFailureCount, 1)
        }
    }

    func testIdenticalRetransmissionsDoNotAlterTheMean() throws {
        let complete = completeNightRows()
        XCTAssertEqual(analyze(complete).aggregate,
                       analyze(Array(complete.reversed()) + Array(repeating: complete[0], count: 100)).aggregate)
    }

    private func analyze(_ rows: [NightLabSpO2FrameRow],
                         baseline: SleepStagerV2BaselineArtifact? = nil) -> NightLabSpO2Diagnostics {
        NightLabSpO2Diagnostics.analyze(rows: rows, windowStartUnix: windowStart,
            windowEndUnix: windowStart + windowDuration, baseline: baseline ?? deepBaseline())
    }

    private func completeNightRows() -> [NightLabSpO2FrameRow] {
        (0..<(windowDuration / 300)).map { frame(timestamp: windowStart + ($0 * 300)) }
    }

    private func frame(timestamp: Int,
                       percentHundredths: UInt16 = 9_725,
                       quality: UInt8 = 90,
                       motionThousandthsG: UInt16 = 10) -> NightLabSpO2FrameRow {
        var bytes = [UInt8](repeating: 0, count: WHOOPSpO2Decoder.frameLength)
        bytes[0] = WHOOPSpO2Decoder.syncByte
        bytes[1] = WHOOPSpO2Decoder.nightlyTelemetrySummaryOpcode
        setUInt32LE(UInt32(timestamp), at: 4, in: &bytes)
        setUInt16LE(percentHundredths, at: 8, in: &bytes)
        bytes[14] = quality
        setUInt16LE(motionThousandthsG, at: 17, in: &bytes)
        let crc = WHOOPSpO2Decoder.crc16CCITTFalse(bytes.prefix(24))
        setUInt16LE(crc, at: 24, in: &bytes)
        return NightLabSpO2FrameRow(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }

    private func deepBaseline(start: Int? = nil,
                              epochsOverride: [SleepStagerV2BaselineEpoch]? = nil) -> SleepStagerV2BaselineArtifact {
        let start = start ?? windowStart
        let end = windowStart + windowDuration
        return SleepStagerV2BaselineArtifact(
            nightID: "spo2-gate-test",
            algorithm: NightAlgorithmIdentity(id: "sleep-stager-v2", version: "2"),
            implementation: SleepStagerV2ImplementationIdentity(
                noopCommitSHA: "test-commit",
                stagerSourceBlobSHA: "test-blob"
            ),
            manifestSchemaVersion: 2,
            sourceStreamFingerprint: "test",
            sourceDeviceID: "test-device",
            sourceDeviceModel: "WHOOP 5.0",
            sourceFirmware: "test",
            sourceStoreSchemaVersion: 18,
            sourceNOOPVersion: "test",
            timezoneOffsetSeconds: 0,
            inputAssets: [],
            windowStartUnix: start,
            windowEndUnix: end,
            productionSegments: [StageSegment(start: start, end: end, stage: "deep")],
            leadingBoundary: nil,
            epochs: epochsOverride ?? stride(from: start, to: end, by: 30).map {
                SleepStagerV2BaselineEpoch(startUnix: $0, endUnix: min($0 + 30, end), stage: .deep)
            }
        )
    }

    private func setUInt16LE(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func setUInt32LE(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
