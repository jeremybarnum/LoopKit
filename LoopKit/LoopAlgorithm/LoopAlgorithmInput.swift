//
//  LoopAlgorithmInput.swift
//  LoopKit
//
//  Created by Pete Schwamb on 9/21/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

public enum DoseRecommendationType: String {
    case manualBolus
    case automaticBolus
    case tempBasal
}

public struct LoopAlgorithmInput {
    public var predictionInput: LoopPredictionInput
    public var predictionDate: Date
    public var doseRecommendationType: DoseRecommendationType

    public init(predictionInput: LoopPredictionInput, predictionDate: Date, doseRecommendationType: DoseRecommendationType) {
        self.predictionInput = predictionInput
        self.predictionDate = predictionDate
        self.doseRecommendationType = doseRecommendationType
    }
}
