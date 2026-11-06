//
//  COBChart.swift
//  LoopUI
//
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import SwiftCharts
import UIKit

public class COBChart: ChartProviding {
    public init() {
    }

    /// The chart points for COB
    public private(set) var cobPoints: [ChartPoint] = [] {
        didSet {
            if let lastDate = cobPoints.last?.x as? ChartAxisValueDate {
                endDate = lastDate.date
            }
        }
    }

    /// The minimum range to display for COB values.
    private var cobDisplayRangePoints: [ChartPoint] = [0, 10].map {
        return ChartPoint(
            x: ChartAxisValue(scalar: 0),
            y: ChartAxisValueInt($0)
        )
    }

    /// Ranges about carbs on board, widest first, each a low and a high series on the same dates: drawn as fills in
    /// place of the area under the line, so where they overlap reads darker. The highs count toward the scale, so a range is never cut off.
    public private(set) var cobRanges: [(low: [ChartPoint], high: [ChartPoint])] = []

    public private(set) var endDate: Date?

    private var cobChartCache: ChartPointsTouchHighlightLayerViewCache?
}

public extension COBChart {
    func didReceiveMemoryWarning() {
        cobPoints = []
        cobRanges = []
        cobChartCache = nil
    }

    func generate(withFrame frame: CGRect, xAxisModel: ChartAxisModel, xAxisValues: [ChartAxisValue], axisLabelSettings: ChartLabelSettings, guideLinesLayerSettings: ChartGuideLinesLayerSettings, colors: ChartColorPalette, chartSettings: ChartSettings, labelsWidthY: CGFloat, gestureRecognizer: UIGestureRecognizer?, traitCollection: UITraitCollection, highlightLabelOffsetY: CGFloat = 0) -> Chart
    {
        let yAxisValues = ChartAxisValuesStaticGenerator.generateYAxisValuesWithChartPoints(cobPoints + cobRanges.flatMap(\.high) + cobDisplayRangePoints, minSegmentCount: 2, maxSegmentCount: 3, multiple: 10, axisValueGenerator: { ChartAxisValueDouble($0, labelSettings: axisLabelSettings) }, addPaddingSegmentIfEdge: false)

        let yAxisModel = ChartAxisModel(axisValues: yAxisValues, lineColor: colors.axisLine, labelSpaceReservationMode: .fixed(labelsWidthY))

        let coordsSpace = ChartCoordsSpaceLeftBottomSingleAxis(chartSettings: chartSettings, chartFrame: frame, xModel: xAxisModel, yModel: yAxisModel)

        let (xAxisLayer, yAxisLayer, innerFrame) = (coordsSpace.xAxisLayer, coordsSpace.yAxisLayer, coordsSpace.chartInnerFrame)

        // The COB area
        let lineModel = ChartLineModel(chartPoints: cobPoints, lineColor: colors.carbTint, lineWidth: 2, animDuration: 0, animDelay: 0)
        let cobLine = ChartPointsLineLayer(xAxis: xAxisLayer.axis, yAxis: yAxisLayer.axis, lineModels: [lineModel])

        let cobArea = ChartPointsFillsLayer(xAxis: xAxisLayer.axis, yAxis: yAxisLayer.axis, fills: [ChartPointsFill(chartPoints: cobPoints, fillColor: colors.carbTint.withAlphaComponent(0.5))])

        let rangeFills = cobRanges.filter { $0.low.count > 1 && $0.low.count == $0.high.count }.map {
            ChartPointsFill(chartPoints: $0.low + $0.high.reversed(), fillColor: colors.carbTint.withAlphaComponent(0.2), createContainerPoints: false)
        }
        let cobRangesLayer: ChartLayer? = rangeFills.isEmpty ? nil : ChartPointsFillsLayer(xAxis: xAxisLayer.axis, yAxis: yAxisLayer.axis, fills: rangeFills)

        // Grid lines
        let gridLayer = ChartGuideLinesForValuesLayer(xAxis: xAxisLayer.axis, yAxis: yAxisLayer.axis, settings: guideLinesLayerSettings, axisValuesX: Array(xAxisValues.dropFirst().dropLast()), axisValuesY: yAxisValues)

        if gestureRecognizer != nil {
            cobChartCache = ChartPointsTouchHighlightLayerViewCache(
                xAxisLayer: xAxisLayer,
                yAxisLayer: yAxisLayer,
                axisLabelSettings: axisLabelSettings,
                chartPoints: cobPoints,
                tintColor: colors.carbTint,
                backgroundColor: colors.background,
                highlightLabelOffsetY: highlightLabelOffsetY,
                gestureRecognizer: gestureRecognizer
            )
        }

        let layers: [ChartLayer?] = [
            gridLayer,
            nowLineLayer(xAxisLayer: xAxisLayer, yAxisLayer: yAxisLayer, color: colors.carbTint),
            xAxisLayer,
            yAxisLayer,
            cobChartCache?.highlightLayer,
            // PRODUCTION: with ranges shown, the line alone over them; the solid area would hide their lower half.
            cobRangesLayer == nil ? cobArea : nil,
            cobRangesLayer,
            cobLine
        ]

        return Chart(frame: frame, innerFrame: innerFrame, settings: chartSettings, layers: layers.compactMap { $0 })
    }
}

public extension COBChart {
    func setCOBValues(_ cobValues: [CarbValue]) {
        let dateFormatter = DateFormatter(timeStyle: .short)
        let integerFormatter = NumberFormatter.integer

        let unit = LoopUnit.gram
        let unitString = unit.unitString

        cobPoints = cobValues.map {
            ChartPoint(
                x: ChartAxisValueDate(date: $0.startDate, formatter: dateFormatter),
                y: ChartAxisValueDoubleUnit($0.quantity.doubleValue(for: unit), unitString: unitString, formatter: integerFormatter)
            )
        }
    }

    /// Ranges about carbs on board ahead, widest first; empty for none.
    func setCOBRanges(_ ranges: [(low: [CarbValue], high: [CarbValue])]) {
        let dateFormatter = DateFormatter(timeStyle: .short)
        func points(_ values: [CarbValue]) -> [ChartPoint] {
            values.map { ChartPoint(x: ChartAxisValueDate(date: $0.startDate, formatter: dateFormatter),
                                    y: ChartAxisValueDouble($0.quantity.doubleValue(for: .gram))) }
        }
        cobRanges = ranges.map { (low: points($0.low), high: points($0.high)) }
    }
}
