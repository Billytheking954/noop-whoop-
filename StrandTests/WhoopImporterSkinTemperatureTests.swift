import XCTest
@testable import Strand

/// Contract for imported WHOOP skin temperature: the CSV carries an ABSOLUTE wrist reading.
/// An absolute reading must never be sent to the deviation field used by NOOP Charge.
final class WhoopImporterSkinTemperatureTests: XCTestCase {
    func testAbsoluteCelsiusIsNeverTreatedAsBaselineDeviation() {
        let mapped = WhoopImporter.temperatureFields(absoluteC: 33.1)
        XCTAssertEqual(mapped.absoluteC, 33.1)
        XCTAssertNil(mapped.deviationC)
    }

    func testMissingTemperatureNeverBecomesAReading() {
        let mapped = WhoopImporter.temperatureFields(absoluteC: nil)
        XCTAssertNil(mapped.absoluteC)
        XCTAssertNil(mapped.deviationC)
    }

    func testImporterVersionChangesWhenColumnSemanticsChange() {
        XCTAssertEqual(WhoopImporter.importerVersion, 2)
    }
}
