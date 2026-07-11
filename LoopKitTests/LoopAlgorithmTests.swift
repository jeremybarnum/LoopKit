//
//  LoopAlgorithmTests.swift
//  LoopKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
@testable import LoopKit

class LoopAlgorithmTests: XCTestCase {

    let start = ISO8601DateFormatter().date(from: "2026-07-11T12:00:00Z")!

    private func fullCoverageSettings() -> LoopAlgorithmSettings {
        let scheduleStart = start.addingTimeInterval(-.hours(24))
        let scheduleEnd = start.addingTimeInterval(.hours(24))
        return LoopAlgorithmSettings(
            basal: [AbsoluteScheduleValue(startDate: scheduleStart, endDate: scheduleEnd, value: 1.0)],
            sensitivity: [AbsoluteScheduleValue(startDate: scheduleStart, endDate: scheduleEnd, value: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 50))],
            carbRatio: [AbsoluteScheduleValue(startDate: scheduleStart, endDate: scheduleEnd, value: 10)],
            target: [AbsoluteScheduleValue(startDate: scheduleStart, endDate: scheduleEnd, value: ClosedRange(uncheckedBounds: (
                lower: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 95),
                upper: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 105))))]
        )
    }

    private func flatGlucoseHistory(value: Double = 120, hours: Double = 10) -> [StoredGlucoseSample] {
        stride(from: -TimeInterval.hours(hours), through: 0, by: .minutes(5)).map {
            StoredGlucoseSample(
                startDate: start.addingTimeInterval($0),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value))
        }
    }

    // MARK: - Codable

    func testSettingsCodableRoundTripPreservesTargetRange() throws {
        let settings = fullCoverageSettings()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(LoopAlgorithmSettings.self, from: encoder.encode(settings))

        XCTAssertEqual(decoded.target.first!.value.lowerBound.doubleValue(for: .milligramsPerDeciliter), 95, accuracy: .ulpOfOne)
        XCTAssertEqual(decoded.target.first!.value.upperBound.doubleValue(for: .milligramsPerDeciliter), 105, accuracy: .ulpOfOne)
    }

    // MARK: - Input validation (previously preconditionFailure crashes)

    func testPredictionThrowsWhenBasalDoesNotCoverDoses() {
        var settings = fullCoverageSettings()
        let dose = DoseEntry(
            type: .bolus,
            startDate: start.addingTimeInterval(-.hours(2)),
            endDate: start.addingTimeInterval(-.hours(2)).addingTimeInterval(.minutes(1)),
            value: 1.0,
            unit: .units)
        // Basal history starts after the dose
        settings.basal = [AbsoluteScheduleValue(startDate: start.addingTimeInterval(-.hours(1)), endDate: start.addingTimeInterval(.hours(24)), value: 1.0)]

        let input = LoopPredictionInput(glucoseHistory: flatGlucoseHistory(), doses: [dose], carbEntries: [], settings: settings)

        XCTAssertThrowsError(try LoopAlgorithm.generatePrediction(input: input)) { error in
            XCTAssertEqual(error as? AlgorithmError, .basalHistoryDoesNotCoverDoses)
        }
    }

    func testPredictionThrowsWhenSensitivityDoesNotCoverDoses() {
        var settings = fullCoverageSettings()
        let dose = DoseEntry(
            type: .bolus,
            startDate: start.addingTimeInterval(-.hours(2)),
            endDate: start.addingTimeInterval(-.hours(2)).addingTimeInterval(.minutes(1)),
            value: 1.0,
            unit: .units)
        settings.sensitivity = [AbsoluteScheduleValue(startDate: start.addingTimeInterval(-.hours(1)), endDate: start.addingTimeInterval(.hours(24)), value: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 50))]

        let input = LoopPredictionInput(glucoseHistory: flatGlucoseHistory(), doses: [dose], carbEntries: [], settings: settings)

        XCTAssertThrowsError(try LoopAlgorithm.generatePrediction(input: input)) { error in
            XCTAssertEqual(error as? AlgorithmError, .sensitivityHistoryDoesNotCoverDoses)
        }
    }

    func testPredictionThrowsWhenSchedulesDoNotCoverCarbEntries() {
        var settings = fullCoverageSettings()
        let carbs = StoredCarbEntry(
            startDate: start.addingTimeInterval(-.hours(2)),
            quantity: HKQuantity(unit: .gram(), doubleValue: 20),
            absorptionTime: .hours(3))
        settings.carbRatio = [AbsoluteScheduleValue(startDate: start.addingTimeInterval(-.hours(1)), endDate: start.addingTimeInterval(.hours(24)), value: 10)]

        let input = LoopPredictionInput(glucoseHistory: flatGlucoseHistory(), doses: [], carbEntries: [carbs], settings: settings)

        XCTAssertThrowsError(try LoopAlgorithm.generatePrediction(input: input)) { error in
            XCTAssertEqual(error as? AlgorithmError, .schedulesDoNotCoverCarbEntries)
        }
    }

    func testPredictionThrowsWithoutGlucose() {
        let input = LoopPredictionInput(glucoseHistory: [], doses: [], carbEntries: [], settings: fullCoverageSettings())

        XCTAssertThrowsError(try LoopAlgorithm.generatePrediction(input: input)) { error in
            XCTAssertEqual(error as? AlgorithmError, .missingGlucose)
        }
    }

    // MARK: - Smoke

    func testFlatGlucoseNoInsulinNoCarbsPredictsFlat() throws {
        let input = LoopPredictionInput(
            glucoseHistory: flatGlucoseHistory(value: 120),
            doses: [],
            carbEntries: [],
            settings: fullCoverageSettings())

        let prediction = try LoopAlgorithm.generatePrediction(input: input)

        XCTAssertFalse(prediction.glucose.isEmpty)
        // Prediction must extend at least the insulin activity duration for dosing math
        XCTAssertGreaterThanOrEqual(
            prediction.glucose.last!.startDate,
            start.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration))
        // Flat history, no insulin, no carbs: eventual BG stays at 120
        XCTAssertEqual(prediction.glucose.last!.quantity.doubleValue(for: .milligramsPerDeciliter), 120, accuracy: 1.0)
    }

    func testBolusLowersPredictionByISF() throws {
        // A 1U bolus at ISF 50 against flat 120 should settle near 70
        let dose = DoseEntry(
            type: .bolus,
            startDate: start.addingTimeInterval(-.minutes(1)),
            endDate: start,
            value: 1.0,
            unit: .units)

        let input = LoopPredictionInput(
            glucoseHistory: flatGlucoseHistory(value: 120),
            doses: [dose],
            carbEntries: [],
            settings: fullCoverageSettings())

        let prediction = try LoopAlgorithm.generatePrediction(input: input)

        XCTAssertEqual(prediction.glucose.last!.quantity.doubleValue(for: .milligramsPerDeciliter), 70, accuracy: 2.0)
    }
}

extension AlgorithmError: Equatable {
    public static func == (lhs: AlgorithmError, rhs: AlgorithmError) -> Bool {
        switch (lhs, rhs) {
        case (.missingGlucose, .missingGlucose),
             (.incompleteSchedules, .incompleteSchedules),
             (.basalHistoryDoesNotCoverDoses, .basalHistoryDoesNotCoverDoses),
             (.sensitivityHistoryDoesNotCoverDoses, .sensitivityHistoryDoesNotCoverDoses),
             (.schedulesDoNotCoverCarbEntries, .schedulesDoNotCoverCarbEntries):
            return true
        default:
            return false
        }
    }
}
