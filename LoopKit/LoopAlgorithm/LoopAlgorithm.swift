//
//  LoopAlgorithm.swift
//  Learn
//
//  Created by Pete Schwamb on 6/30/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit

public enum AlgorithmError: Error {
    case missingGlucose
    case incompleteSchedules
    case basalHistoryDoesNotCoverDoses
    case sensitivityHistoryDoesNotCoverDoses
    case schedulesDoNotCoverCarbEntries
    case missingMaximumBasalRate
    case missingMaximumBolus
}

public struct LoopAlgorithmEffects {
    public var insulin: [GlucoseEffect]
    public var carbs: [GlucoseEffect]
    public var retrospectiveCorrection: [GlucoseEffect]
    public var momentum: [GlucoseEffect]
    public var insulinCounteraction: [GlucoseEffectVelocity]
}

public struct AlgorithmEffectsOptions: OptionSet {
    public let rawValue: UInt8

    public static let carbs            = AlgorithmEffectsOptions(rawValue: 1 << 0)
    public static let insulin          = AlgorithmEffectsOptions(rawValue: 1 << 1)
    public static let momentum         = AlgorithmEffectsOptions(rawValue: 1 << 2)
    public static let retrospection    = AlgorithmEffectsOptions(rawValue: 1 << 3)

    public static let all: AlgorithmEffectsOptions = [.carbs, .insulin, .momentum, .retrospection]

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public struct LoopPrediction: GlucosePrediction {
    public var glucose: [PredictedGlucoseValue]
    public var effects: LoopAlgorithmEffects
}

public struct DoseRecommendation: Equatable {
    public let basalAdjustment: TempBasalRecommendation?
    public let bolusUnits: Double?

    public init(basalAdjustment: TempBasalRecommendation?, bolusUnits: Double? = nil) {
        self.basalAdjustment = basalAdjustment
        self.bolusUnits = bolusUnits
    }
}

public actor LoopAlgorithm {

    public typealias InputType = LoopPredictionInput
    public typealias OutputType = LoopPrediction

    /// Generates a glucose prediction and a dose recommendation to correct it.
    ///
    /// The prediction runs on the absolute timelines in `input.predictionInput.settings`;
    /// the dosing math consumes daily schedules, so those are passed alongside — the same
    /// split the phone's live path (LoopDataManager) has. Dosing limits come from
    /// `settings.maximumBasalRatePerHour` / `settings.maximumBolus` and are required for
    /// the corresponding recommendation types.
    public static func generateRecommendation(
        input: LoopAlgorithmInput,
        correctionRange: GlucoseRangeSchedule,
        sensitivity: InsulinSensitivitySchedule,
        basalRates: BasalRateSchedule,
        model: InsulinModel,
        pendingInsulin: Double = 0,
        lastTempBasal: DoseEntry? = nil,
        automaticBolusApplicationFactor: Double = 0.4
    ) throws -> (prediction: LoopPrediction, recommendation: DoseRecommendation) {
        let prediction = try generatePrediction(input: input.predictionInput, startDate: input.predictionDate)

        let settings = input.predictionInput.settings
        let date = input.predictionDate
        let suspendThreshold = settings.suspendThreshold?.quantity

        switch input.doseRecommendationType {
        case .manualBolus:
            guard let maxBolus = settings.maximumBolus else {
                throw AlgorithmError.missingMaximumBolus
            }
            let bolus = prediction.glucose.recommendedManualBolus(
                to: correctionRange,
                at: date,
                suspendThreshold: suspendThreshold,
                sensitivity: sensitivity,
                model: model,
                pendingInsulin: pendingInsulin,
                maxBolus: maxBolus)
            return (prediction, DoseRecommendation(basalAdjustment: nil, bolusUnits: bolus.amount))
        case .automaticBolus:
            guard let maxBolus = settings.maximumBolus else {
                throw AlgorithmError.missingMaximumBolus
            }
            let dose = prediction.glucose.recommendedAutomaticDose(
                to: correctionRange,
                at: date,
                suspendThreshold: suspendThreshold,
                sensitivity: sensitivity,
                model: model,
                basalRates: basalRates,
                maxAutomaticBolus: maxBolus,
                partialApplicationFactor: automaticBolusApplicationFactor,
                lastTempBasal: lastTempBasal)
            return (prediction, DoseRecommendation(basalAdjustment: dose?.basalAdjustment, bolusUnits: dose?.bolusUnits))
        case .tempBasal:
            guard let maxBasalRate = settings.maximumBasalRatePerHour else {
                throw AlgorithmError.missingMaximumBasalRate
            }
            let temp = prediction.glucose.recommendedTempBasal(
                to: correctionRange,
                at: date,
                suspendThreshold: suspendThreshold,
                sensitivity: sensitivity,
                model: model,
                basalRates: basalRates,
                maxBasalRate: maxBasalRate,
                lastTempBasal: lastTempBasal)
            return (prediction, DoseRecommendation(basalAdjustment: temp))
        }
    }

    // Generates a forecast predicting glucose.
    public static func generatePrediction(input: LoopPredictionInput, startDate: Date? = nil) throws -> LoopPrediction {

        guard let latestGlucose = input.glucoseHistory.last else {
            throw AlgorithmError.missingGlucose
        }

        let start = startDate ?? latestGlucose.startDate

        let insulinModelProvider = PresetInsulinModelProvider(defaultRapidActingModel: nil)

        let settings = input.settings

        // Validate schedule coverage up front. The math below enforces these with
        // preconditionFailure (InsulinMath, CarbMath); on the watch, misaligned
        // handover inputs must surface as a recoverable error, not a crash.
        if let earliestDoseStart = input.doses.map(\.startDate).min() {
            guard let basalStart = settings.basal.first?.startDate, basalStart <= earliestDoseStart else {
                throw AlgorithmError.basalHistoryDoesNotCoverDoses
            }
            for dose in input.doses {
                guard let isf = settings.sensitivity.closestPrior(to: dose.startDate), isf.endDate >= dose.startDate else {
                    throw AlgorithmError.sensitivityHistoryDoesNotCoverDoses
                }
            }
        }

        for entry in input.carbEntries {
            guard settings.sensitivity.closestPrior(to: entry.startDate) != nil,
                  settings.carbRatio.closestPrior(to: entry.startDate) != nil else {
                throw AlgorithmError.schedulesDoNotCoverCarbEntries
            }
        }

        // Overlay basal history on basal doses, splitting doses to get amount delivered relative to basal
        let annotatedDoses = input.doses.annotated(with: input.settings.basal)

        let insulinEffects = annotatedDoses.glucoseEffects(
            insulinModelProvider: insulinModelProvider,
            longestEffectDuration: settings.insulinActivityDuration,
            insulinSensitivityHistory: settings.sensitivity,
            from: start.addingTimeInterval(-CarbMath.maximumAbsorptionTimeInterval).dateFlooredToTimeInterval(settings.delta),
            to: nil)

        // ICE
        let insulinCounteractionEffects = input.glucoseHistory.counteractionEffects(to: insulinEffects)

        // Carb Effects
        let carbEffects = input.carbEntries.map(
            to: insulinCounteractionEffects,
            carbRatio: settings.carbRatio,
            insulinSensitivity: settings.sensitivity
        ).dynamicGlucoseEffects(
            from: start.addingTimeInterval(-IntegralRetrospectiveCorrection.retrospectionInterval),
            carbRatios: settings.carbRatio,
            insulinSensitivities: settings.sensitivity
        )

        // RC
        let retrospectiveGlucoseDiscrepancies = insulinCounteractionEffects.subtracting(carbEffects)
        let retrospectiveGlucoseDiscrepanciesSummed = retrospectiveGlucoseDiscrepancies.combinedSums(of: LoopMath.retrospectiveCorrectionGroupingInterval * 1.01)

        let rc: RetrospectiveCorrection

        if input.settings.useIntegralRetrospectiveCorrection {
            rc = IntegralRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
        } else {
            rc = StandardRetrospectiveCorrection(effectDuration: LoopMath.retrospectiveCorrectionEffectDuration)
        }

        guard let curSensitivity = settings.sensitivity.closestPrior(to: start)?.value,
              let curBasal = settings.basal.closestPrior(to: start)?.value,
              let curTarget = settings.target.closestPrior(to: start)?.value else
        {
            throw AlgorithmError.incompleteSchedules
        }

        let rcEffect = rc.computeEffect(
            startingAt: latestGlucose,
            retrospectiveGlucoseDiscrepanciesSummed: retrospectiveGlucoseDiscrepanciesSummed,
            recencyInterval: TimeInterval(minutes: 15),
            insulinSensitivity: curSensitivity,
            basalRate: curBasal,
            correctionRange: curTarget,
            retrospectiveCorrectionGroupingInterval: LoopMath.retrospectiveCorrectionGroupingInterval
        )

        var effects = [[GlucoseEffect]]()

        if settings.algorithmEffectsOptions.contains(.carbs) {
            effects.append(carbEffects)
        }

        if settings.algorithmEffectsOptions.contains(.insulin) {
            effects.append(insulinEffects)
        }

        if settings.algorithmEffectsOptions.contains(.retrospection) {
            effects.append(rcEffect)
        }

        // Glucose Momentum
        let momentumEffects: [GlucoseEffect]
        if settings.algorithmEffectsOptions.contains(.momentum) {
            let momentumInputData = input.glucoseHistory.filterDateRange(start.addingTimeInterval(-GlucoseMath.momentumDataInterval), start)
            momentumEffects = momentumInputData.linearMomentumEffect()
        } else {
            momentumEffects = []
        }

        var prediction = LoopMath.predictGlucose(startingAt: latestGlucose, momentum: momentumEffects, effects: effects)

        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = latestGlucose.startDate.addingTimeInterval(InsulinMath.defaultInsulinActivityDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }

        return LoopPrediction(
            glucose: prediction,
            effects: LoopAlgorithmEffects(
                insulin: insulinEffects,
                carbs: carbEffects,
                retrospectiveCorrection: rcEffect,
                momentum: momentumEffects,
                insulinCounteraction: insulinCounteractionEffects
            )
        )
    }
}


