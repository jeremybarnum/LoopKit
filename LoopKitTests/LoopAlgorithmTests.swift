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

    // MARK: - Dose recommendations

    private func dosingSchedules() -> (correctionRange: GlucoseRangeSchedule, sensitivity: InsulinSensitivitySchedule, basalRates: BasalRateSchedule) {
        let correctionRange = GlucoseRangeSchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 95, maxValue: 105))])!
        let sensitivity = InsulinSensitivitySchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50.0)])!
        let basalRates = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)])!
        return (correctionRange, sensitivity, basalRates)
    }

    private func recommendation(glucose: Double, type: DoseRecommendationType, maxBolus: Double = 5, maxBasalRate: Double = 3, suspendThreshold: GlucoseThreshold? = nil) throws -> (prediction: LoopPrediction, recommendation: DoseRecommendation) {
        var settings = fullCoverageSettings()
        settings.maximumBolus = maxBolus
        settings.maximumBasalRatePerHour = maxBasalRate
        settings.suspendThreshold = suspendThreshold

        let input = LoopAlgorithmInput(
            predictionInput: LoopPredictionInput(
                glucoseHistory: flatGlucoseHistory(value: glucose),
                doses: [],
                carbEntries: [],
                settings: settings),
            predictionDate: start,
            doseRecommendationType: type)

        let schedules = dosingSchedules()
        return try LoopAlgorithm.generateRecommendation(
            input: input,
            correctionRange: schedules.correctionRange,
            sensitivity: schedules.sensitivity,
            basalRates: schedules.basalRates,
            model: ExponentialInsulinModelPreset.rapidActingAdult)
    }

    func testManualBolusRecommendationForHighGlucose() throws {
        // Flat 180 vs target 95-105 at ISF 50: correction is ~1.5-1.7 U
        let (_, rec) = try recommendation(glucose: 180, type: .manualBolus)
        XCTAssertNil(rec.basalAdjustment)
        XCTAssertEqual(rec.bolusUnits!, 1.6, accuracy: 0.25)
    }

    func testManualBolusRespectsMaxBolus() throws {
        let (_, rec) = try recommendation(glucose: 350, type: .manualBolus, maxBolus: 1.0)
        XCTAssertEqual(rec.bolusUnits!, 1.0, accuracy: .ulpOfOne)
    }

    func testManualBolusZeroWhenInRange() throws {
        let (_, rec) = try recommendation(glucose: 100, type: .manualBolus)
        XCTAssertEqual(rec.bolusUnits!, 0, accuracy: .ulpOfOne)
    }

    func testTempBasalRecommendationForHighGlucose() throws {
        let (_, rec) = try recommendation(glucose: 180, type: .tempBasal)
        let temp = try XCTUnwrap(rec.basalAdjustment)
        XCTAssertGreaterThan(temp.unitsPerHour, 1.0) // above scheduled basal
        XCTAssertLessThanOrEqual(temp.unitsPerHour, 3.0) // clamped by max
    }

    func testTempBasalZeroWhenPredictionBelowSuspendThreshold() throws {
        let (_, rec) = try recommendation(
            glucose: 60,
            type: .tempBasal,
            suspendThreshold: GlucoseThreshold(unit: .milligramsPerDeciliter, value: 65))
        let temp = try XCTUnwrap(rec.basalAdjustment)
        XCTAssertEqual(temp.unitsPerHour, 0, accuracy: .ulpOfOne)
    }

    func testRecommendationThrowsWithoutMaxBolus() {
        var settings = fullCoverageSettings()
        settings.maximumBolus = nil
        let input = LoopAlgorithmInput(
            predictionInput: LoopPredictionInput(glucoseHistory: flatGlucoseHistory(), doses: [], carbEntries: [], settings: settings),
            predictionDate: start,
            doseRecommendationType: .manualBolus)
        let schedules = dosingSchedules()

        XCTAssertThrowsError(try LoopAlgorithm.generateRecommendation(
            input: input,
            correctionRange: schedules.correctionRange,
            sensitivity: schedules.sensitivity,
            basalRates: schedules.basalRates,
            model: ExponentialInsulinModelPreset.rapidActingAdult)) { error in
            XCTAssertEqual(error as? AlgorithmError, .missingMaximumBolus)
        }
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
             (.schedulesDoNotCoverCarbEntries, .schedulesDoNotCoverCarbEntries),
             (.missingMaximumBasalRate, .missingMaximumBasalRate),
             (.missingMaximumBolus, .missingMaximumBolus):
            return true
        default:
            return false
        }
    }
}
