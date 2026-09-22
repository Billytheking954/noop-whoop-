import Foundation
import XCTest
@testable import StrandHealth

final class CanonicalEvidenceTests: XCTestCase {

    func testSDNNAndRMSSDRemainSemanticallyDistinct() {
        XCTAssertNotEqual(HealthMetricKind.heartRateVariabilitySDNN,
                          HealthMetricKind.heartRateVariabilityRMSSD)
        XCTAssertEqual(HealthMetricKind.heartRateVariabilitySDNN.rawValue,
                       "heartRateVariability.sdnn")
        XCTAssertEqual(HealthMetricKind.heartRateVariabilityRMSSD.rawValue,
                       "heartRateVariability.rmssd")
    }

    func testMetricKindsRemainForwardCompatibleAndEncodeAsStrings() throws {
        let custom = HealthMetricKind(rawValue: "future.provider.metric")
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"future.provider.metric\"")
        XCTAssertEqual(try JSONDecoder().decode(HealthMetricKind.self, from: data), custom)
    }

    func testObservationRoundTripPreservesProvenanceAndQuality() throws {
        let source = SourceIdentity(provider: "healthkit",
                                    identifier: "com.apple.health",
                                    displayName: "Apple Health")
        let device = DeviceIdentity(identifier: "watch-1",
                                    manufacturer: "Apple",
                                    model: "Watch",
                                    hardwareVersion: "test-hw",
                                    firmwareVersion: "test-fw")
        let record = ObservationRecord(
            id: "sample-1",
            metric: .heartRate,
            value: MetricValue(value: 62, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 1_001),
            quality: ObservationQuality(state: .nominal,
                                        coverageFraction: 1,
                                        flags: ["provider-verified"]),
            provenance: ObservationProvenance(classification: .measured,
                                              source: source,
                                              device: device,
                                              providerIdentifier: "hk-123",
                                              externalIdentifier: "external-123"),
            ingestedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNoThrow(try CanonicalEvidenceValidator.validate(record))
        let decoded = try JSONDecoder().decode(
            ObservationRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.provenance.device?.firmwareVersion, "test-fw")
        XCTAssertEqual(decoded.provenance.providerIdentifier, "hk-123")
    }

    func testExperimentalClassificationSurvivesRoundTrip() throws {
        let record = ObservationRecord(
            id: "research-1",
            metric: .oxygenSaturation,
            value: MetricValue(value: 96, unit: .percent),
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 100),
            provenance: ObservationProvenance(
                classification: .experimental,
                source: SourceIdentity(provider: "whoop-research",
                                       identifier: "summary-frame-hypothesis")
            ),
            ingestedAt: Date(timeIntervalSince1970: 101)
        )

        let decoded = try JSONDecoder().decode(
            ObservationRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.provenance.classification, .experimental)
        XCTAssertNoThrow(try CanonicalEvidenceValidator.validate(decoded))
    }

    func testObservationValidatorRejectsNonFiniteValue() {
        let record = observation(value: .infinity)
        XCTAssertThrowsError(try CanonicalEvidenceValidator.validate(record)) { error in
            XCTAssertEqual(error as? CanonicalEvidenceValidationError, .nonFiniteMetricValue)
        }
    }

    func testObservationValidatorRejectsInvertedInterval() {
        let record = ObservationRecord(
            id: "bad-window",
            metric: .heartRate,
            value: MetricValue(value: 60, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 100),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: "test", identifier: "fixture")
            ),
            ingestedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertThrowsError(try CanonicalEvidenceValidator.validate(record)) { error in
            XCTAssertEqual(error as? CanonicalEvidenceValidationError, .invalidTimeRange)
        }
    }

    func testObservationValidatorRejectsImpossibleCoverage() {
        let record = ObservationRecord(
            id: "bad-coverage",
            metric: .heartRate,
            value: MetricValue(value: 60, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 101),
            quality: ObservationQuality(state: .degraded, coverageFraction: 1.01),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: "test", identifier: "fixture")
            ),
            ingestedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertThrowsError(try CanonicalEvidenceValidator.validate(record)) { error in
            XCTAssertEqual(error as? CanonicalEvidenceValidationError, .invalidCoverageFraction)
        }
    }

    func testDerivedMetricPreservesAlgorithmIdentityAndFingerprint() throws {
        let record = DerivedMetricRecord(
            id: "derived-1",
            metric: .sleepDuration,
            value: MetricValue(value: 27_000, unit: .seconds),
            classification: .derived,
            inputStartDate: Date(timeIntervalSince1970: 1_000),
            inputEndDate: Date(timeIntervalSince1970: 28_000),
            algorithm: AlgorithmIdentity(identifier: "sleep-duration",
                                         version: "1.0.0",
                                         implementationRevision: "abc123"),
            inputFingerprint: "sha256:fixture",
            generatedAt: Date(timeIntervalSince1970: 28_001),
            evidenceQuality: ObservationQuality(state: .nominal, coverageFraction: 0.98),
            validationStatus: .internallyValidated
        )

        XCTAssertNoThrow(try CanonicalEvidenceValidator.validate(record))
        let decoded = try JSONDecoder().decode(
            DerivedMetricRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.algorithm.version, "1.0.0")
        XCTAssertEqual(decoded.inputFingerprint, "sha256:fixture")
    }

    func testDerivedMetricCannotMasqueradeAsMeasuredEvidence() {
        let record = DerivedMetricRecord(
            id: "bad-derived",
            metric: .restingHeartRate,
            value: MetricValue(value: 55, unit: .beatsPerMinute),
            classification: .measured,
            inputStartDate: Date(timeIntervalSince1970: 100),
            inputEndDate: Date(timeIntervalSince1970: 200),
            algorithm: AlgorithmIdentity(identifier: "rhr", version: "1"),
            inputFingerprint: "sha256:test",
            generatedAt: Date(timeIntervalSince1970: 201)
        )

        XCTAssertThrowsError(try CanonicalEvidenceValidator.validate(record)) { error in
            XCTAssertEqual(error as? CanonicalEvidenceValidationError, .measuredDerivedMetric)
        }
    }

    private func observation(value: Double) -> ObservationRecord {
        ObservationRecord(
            id: "fixture",
            metric: .heartRate,
            value: MetricValue(value: value, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 101),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: "test", identifier: "fixture")
            ),
            ingestedAt: Date(timeIntervalSince1970: 200)
        )
    }
}
