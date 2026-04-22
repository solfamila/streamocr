import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct OCRRegionPreprocessResult {
    let pixelBuffer: CVPixelBuffer
    let cropMilliseconds: Double
    let metalMilliseconds: Double
}

enum OCRPixelBufferFactory {
    static func makeOutputPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }
}

final class OCRRegionPreprocessor {
    private let ciContext: CIContext

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    func preprocess(
        sourcePixelBuffer: CVPixelBuffer,
        roi: PixelRect,
        region: OCRRegionKind
    ) -> OCRRegionPreprocessResult? {
        let imageWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
        guard imageWidth > 0, imageHeight > 0 else {
            return nil
        }

        let cropPreparationStart = CFAbsoluteTimeGetCurrent()

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        let ciY = imageHeight - roi.y - roi.height
        let rawCropRect = CGRect(x: roi.x, y: ciY, width: roi.width, height: roi.height).integral
        let boundedCropRect = rawCropRect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard boundedCropRect.width >= 1, boundedCropRect.height >= 1 else {
            return nil
        }

        let croppedImage = sourceImage
            .cropped(to: boundedCropRect)
            .transformed(by: CGAffineTransform(translationX: -boundedCropRect.origin.x, y: -boundedCropRect.origin.y))
        let cropMilliseconds = elapsedMilliseconds(since: cropPreparationStart)

        let metalStart = CFAbsoluteTimeGetCurrent()
        let scaleFactor = preprocessScaleFactor(for: region, roi: roi)
        let upscaledImage = croppedImage.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scaleFactor,
                kCIInputAspectRatioKey: 1.0
            ]
        )

        let filteredImage = upscaledImage
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: region == .manualCell ? 2.1 : 1.55,
                    kCIInputBrightnessKey: region == .manualCell ? 0.01 : 0.02
                ]
            )
            .applyingFilter(
                "CIGammaAdjust",
                parameters: [
                    "inputPower": region == .manualCell ? 0.72 : 0.82
                ]
            )
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: region == .manualCell ? 0.9 : 0.45
                ]
            )
            .applyingFilter(
                "CIUnsharpMask",
                parameters: [
                    kCIInputRadiusKey: region == .manualCell ? 1.2 : 0.8,
                    kCIInputIntensityKey: region == .manualCell ? 0.65 : 0.3
                ]
            )

        let outputWidth = max(1, Int(filteredImage.extent.width.rounded(.up)))
        let outputHeight = max(1, Int(filteredImage.extent.height.rounded(.up)))
        guard let outputPixelBuffer = OCRPixelBufferFactory.makeOutputPixelBuffer(width: outputWidth, height: outputHeight) else {
            return nil
        }

        ciContext.render(
            filteredImage,
            to: outputPixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        if region == .manualCell {
            let threshold = adaptiveThreshold(for: outputPixelBuffer)
            binarize(pixelBuffer: outputPixelBuffer, threshold: threshold)
            removeSmallForegroundComponents(pixelBuffer: outputPixelBuffer)
        }
        let metalMilliseconds = elapsedMilliseconds(since: metalStart)

        return OCRRegionPreprocessResult(
            pixelBuffer: outputPixelBuffer,
            cropMilliseconds: cropMilliseconds,
            metalMilliseconds: metalMilliseconds
        )
    }

    func preprocessFullFrame(
        _ pixelBuffer: CVPixelBuffer,
        region: OCRRegionKind
    ) -> CVPixelBuffer? {
        let roi = PixelRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        return preprocess(sourcePixelBuffer: pixelBuffer, roi: roi, region: region)?.pixelBuffer
    }

    private func preprocessScaleFactor(for region: OCRRegionKind, roi: PixelRect) -> CGFloat {
        let targetHeight: CGFloat
        switch region {
        case .manualCell:
            targetHeight = 112
        case .manualSymbolCell:
            targetHeight = 88
        }

        let rawScale = targetHeight / max(1, CGFloat(roi.height))
        return max(1, min(4, ceil(rawScale)))
    }

    private func adaptiveThreshold(for pixelBuffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 128
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var minLuma = 255
        var maxLuma = 0
        var totalLuma = 0
        var sampleCount = 0

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width * 4, by: 4) {
                let blue = Int(row[x])
                let green = Int(row[x + 1])
                let red = Int(row[x + 2])
                let luma = (299 * red + 587 * green + 114 * blue) / 1000
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
                totalLuma += luma
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return 128
        }

        let midpoint = (minLuma + maxLuma) / 2
        let mean = totalLuma / sampleCount
        let blended = (midpoint + mean) / 2
        return UInt8(max(48, min(216, blended)))
    }

    private func binarize(pixelBuffer: CVPixelBuffer, threshold: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width * 4, by: 4) {
                let blue = Int(row[x])
                let green = Int(row[x + 1])
                let red = Int(row[x + 2])
                let luma = UInt8((299 * red + 587 * green + 114 * blue) / 1000)
                let output: UInt8 = luma >= threshold ? 255 : 0
                row[x] = output
                row[x + 1] = output
                row[x + 2] = output
                row[x + 3] = 255
            }
        }
    }

    private func removeSmallForegroundComponents(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else {
            return
        }

        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var visited = Array(repeating: false, count: width * height)
        let minimumArea = max(12, (width * height) / 450)
        let maximumNoiseHeight = max(8, height / 4)

        for y in 0..<height {
            for x in 0..<width {
                let visitIndex = (y * width) + x
                guard !visited[visitIndex] else {
                    continue
                }

                visited[visitIndex] = true
                let offset = (y * bytesPerRow) + (x * 4)
                guard pointer[offset + 2] >= 128 else {
                    continue
                }

                var queue = [(x: x, y: y)]
                var componentPixels: [(x: Int, y: Int)] = []
                componentPixels.reserveCapacity(32)

                var minY = y
                var maxY = y

                while !queue.isEmpty {
                    let current = queue.removeLast()
                    componentPixels.append(current)
                    minY = min(minY, current.y)
                    maxY = max(maxY, current.y)

                    for neighborY in max(0, current.y - 1)...min(height - 1, current.y + 1) {
                        for neighborX in max(0, current.x - 1)...min(width - 1, current.x + 1) {
                            let neighborIndex = (neighborY * width) + neighborX
                            guard !visited[neighborIndex] else {
                                continue
                            }

                            visited[neighborIndex] = true
                            let neighborOffset = (neighborY * bytesPerRow) + (neighborX * 4)
                            guard pointer[neighborOffset + 2] >= 128 else {
                                continue
                            }

                            queue.append((neighborX, neighborY))
                        }
                    }
                }

                let componentHeight = maxY - minY + 1
                let shouldRemove = componentPixels.count < minimumArea && componentHeight <= maximumNoiseHeight
                guard shouldRemove else {
                    continue
                }

                for pixel in componentPixels {
                    let pixelOffset = (pixel.y * bytesPerRow) + (pixel.x * 4)
                    pointer[pixelOffset] = 0
                    pointer[pixelOffset + 1] = 0
                    pointer[pixelOffset + 2] = 0
                    pointer[pixelOffset + 3] = 255
                }
            }
        }
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        max(0, (CFAbsoluteTimeGetCurrent() - start) * 1_000)
    }
}

private struct GlyphSegmentationRange {
    let start: Int
    let endInclusive: Int
}

enum GlyphSegmentationPolicy {
    static func segmentGlyphRects(
        in pixelBuffer: CVPixelBuffer,
        region: OCRRegionKind
    ) -> [CGRect] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        guard width > 0, height > 0 else {
            return []
        }

        let threshold = dynamicForegroundThreshold(
            pointer: pointer,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )

        var columnForegroundCounts = Array(repeating: 0, count: width)
        var columnMinY = Array(repeating: height, count: width)
        var columnMaxY = Array(repeating: -1, count: width)

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let offset = x * 4
                let luma = Int(row[offset + 2])
                guard luma >= threshold else {
                    continue
                }

                columnForegroundCounts[x] += 1
                columnMinY[x] = min(columnMinY[x], y)
                columnMaxY[x] = max(columnMaxY[x], y)
            }
        }

        let mergeGap = region == .manualCell ? 1 : 3
        let rawSegments = contiguousSegments(
            from: columnForegroundCounts,
            mergeGap: mergeGap
        )
        let refinedSegments: [GlyphSegmentationRange]
        if region == .manualCell {
            refinedSegments = splitCompositeSegmentsIfNeeded(
                rawSegments,
                columnForegroundCounts: columnForegroundCounts,
                height: height
            )
        } else {
            refinedSegments = rawSegments
        }

        let minAreaRatio = region == .manualCell ? 0.012 : 0.008
        let maxSegments = region == .manualCell ? 8 : 6

        var segments: [CGRect] = []
        segments.reserveCapacity(refinedSegments.count)

        for rawSegment in refinedSegments {
            let area = (rawSegment.start...rawSegment.endInclusive).reduce(0) { partial, x in
                partial + columnForegroundCounts[x]
            }

            let areaRatio = Double(area) / Double(width * height)
            guard areaRatio >= minAreaRatio else {
                continue
            }

            let top = (rawSegment.start...rawSegment.endInclusive).map { columnMinY[$0] }.min() ?? 0
            let bottom = (rawSegment.start...rawSegment.endInclusive).map { columnMaxY[$0] }.max() ?? (height - 1)
            guard bottom >= top else {
                continue
            }

            let paddedRect = CGRect(
                x: max(0, rawSegment.start - 2),
                y: max(0, top - 2),
                width: min(width - max(0, rawSegment.start - 2), rawSegment.endInclusive - rawSegment.start + 1 + 4),
                height: min(height - max(0, top - 2), bottom - top + 1 + 4)
            ).integral

            guard paddedRect.width >= 2, paddedRect.height >= 2 else {
                continue
            }

            segments.append(paddedRect)
        }

        if segments.count > maxSegments {
            return Array(segments.prefix(maxSegments))
        }

        return segments
    }

    private static func splitCompositeSegmentsIfNeeded(
        _ segments: [GlyphSegmentationRange],
        columnForegroundCounts: [Int],
        height: Int
    ) -> [GlyphSegmentationRange] {
        guard !segments.isEmpty else {
            return []
        }

        var refined: [GlyphSegmentationRange] = []
        refined.reserveCapacity(segments.count * 2)

        let estimatedSingleGlyphWidth = max(10, Int((Double(height) * 0.34).rounded()))

        for segment in segments {
            let width = segment.endInclusive - segment.start + 1
            if width <= Int(Double(estimatedSingleGlyphWidth) * 1.45) {
                refined.append(segment)
                continue
            }

            let splitCount = min(4, max(2, Int((Double(width) / Double(estimatedSingleGlyphWidth)).rounded())))
            let cuts = splitPoints(
                within: segment,
                desiredSegments: splitCount,
                columnForegroundCounts: columnForegroundCounts
            )

            if cuts.isEmpty {
                refined.append(contentsOf: evenlySplit(segment, desiredSegments: splitCount))
                continue
            }

            let segmented = split(segment, at: cuts)
            refined.append(contentsOf: segmented.isEmpty ? [segment] : segmented)
        }

        return refined
    }

    private static func splitPoints(
        within segment: GlyphSegmentationRange,
        desiredSegments: Int,
        columnForegroundCounts: [Int]
    ) -> [Int] {
        guard desiredSegments > 1 else {
            return []
        }

        let values = Array(columnForegroundCounts[segment.start...segment.endInclusive])
        guard let maxValue = values.max(), maxValue > 0 else {
            return []
        }

        let lowForegroundThreshold = max(1, Int(Double(maxValue) * 0.32))
        let minimumSubsegmentWidth = max(6, values.count / (desiredSegments * 2))

        var candidateCutGroups: [[Int]] = []
        var currentGroup: [Int] = []

        for (offset, value) in values.enumerated() {
            let absoluteIndex = segment.start + offset
            let isInterior = absoluteIndex > segment.start && absoluteIndex < segment.endInclusive
            let isLowForeground = isInterior && value <= lowForegroundThreshold

            if isLowForeground {
                currentGroup.append(absoluteIndex)
            } else if !currentGroup.isEmpty {
                candidateCutGroups.append(currentGroup)
                currentGroup.removeAll(keepingCapacity: true)
            }
        }

        if !currentGroup.isEmpty {
            candidateCutGroups.append(currentGroup)
        }

        let candidateCuts = candidateCutGroups
            .map { group in group[group.count / 2] }
            .sorted()

        guard !candidateCuts.isEmpty else {
            return []
        }

        var selectedCuts: [Int] = []
        selectedCuts.reserveCapacity(desiredSegments - 1)

        let targetCuts = desiredSegments - 1
        let idealSpacing = Double(values.count) / Double(desiredSegments)

        for cut in candidateCuts {
            let previousBoundary = (selectedCuts.last ?? segment.start) - segment.start
            let nextRemaining = targetCuts - selectedCuts.count - 1
            let remainingWidth = segment.endInclusive - cut
            let minimumRemainingWidth = nextRemaining * minimumSubsegmentWidth

            guard (cut - segment.start) - previousBoundary >= minimumSubsegmentWidth else {
                continue
            }

            guard remainingWidth >= minimumRemainingWidth else {
                continue
            }

            if selectedCuts.isEmpty {
                let distanceFromIdeal = abs(Double(cut - segment.start) - idealSpacing)
                if distanceFromIdeal > idealSpacing {
                    continue
                }
            }

            selectedCuts.append(cut)
            if selectedCuts.count == targetCuts {
                break
            }
        }

        return selectedCuts
    }

    private static func split(
        _ segment: GlyphSegmentationRange,
        at cuts: [Int]
    ) -> [GlyphSegmentationRange] {
        guard !cuts.isEmpty else {
            return [segment]
        }

        var output: [GlyphSegmentationRange] = []
        var start = segment.start

        for cut in cuts.sorted() {
            let end = max(start, cut - 1)
            output.append(GlyphSegmentationRange(start: start, endInclusive: end))
            start = cut
        }

        output.append(GlyphSegmentationRange(start: start, endInclusive: segment.endInclusive))
        return output.filter { $0.endInclusive >= $0.start }
    }

    private static func evenlySplit(
        _ segment: GlyphSegmentationRange,
        desiredSegments: Int
    ) -> [GlyphSegmentationRange] {
        guard desiredSegments > 1 else {
            return [segment]
        }

        let width = segment.endInclusive - segment.start + 1
        guard width >= desiredSegments else {
            return [segment]
        }

        var output: [GlyphSegmentationRange] = []
        output.reserveCapacity(desiredSegments)

        for index in 0..<desiredSegments {
            let start = segment.start + (width * index) / desiredSegments
            let nextStart = segment.start + (width * (index + 1)) / desiredSegments
            let end = nextStart - 1
            output.append(GlyphSegmentationRange(start: start, endInclusive: end))
        }

        return output.filter { $0.endInclusive >= $0.start }
    }

    static func makeGlyphPixelBuffer(
        from sourcePixelBuffer: CVPixelBuffer,
        rect: CGRect,
        ciContext: CIContext,
        targetSide: Int = 64
    ) -> CVPixelBuffer? {
        let padding: CGFloat = 6
        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        let croppedImage = sourceImage
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))

        let usableSide = CGFloat(targetSide) - (padding * 2)
        let scale = min(
            usableSide / max(rect.width, 1),
            usableSide / max(rect.height, 1)
        )

        let scaledWidth = rect.width * scale
        let scaledHeight = rect.height * scale
        let translatedX = ((CGFloat(targetSide) - scaledWidth) / 2).rounded(.towardZero)
        let translatedY = ((CGFloat(targetSide) - scaledHeight) / 2).rounded(.towardZero)

        let scaledImage = croppedImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: translatedX, y: translatedY))

        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: targetSide, height: targetSide))
        let composited = scaledImage.composited(over: background)

        guard let outputPixelBuffer = OCRPixelBufferFactory.makeOutputPixelBuffer(width: targetSide, height: targetSide) else {
            return nil
        }

        ciContext.render(
            composited,
            to: outputPixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: targetSide, height: targetSide),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return outputPixelBuffer
    }

    private static func contiguousSegments(
        from foregroundCounts: [Int],
        mergeGap: Int
    ) -> [GlyphSegmentationRange] {
        var segments: [GlyphSegmentationRange] = []
        var index = 0

        while index < foregroundCounts.count {
            while index < foregroundCounts.count, foregroundCounts[index] == 0 {
                index += 1
            }

            guard index < foregroundCounts.count else {
                break
            }

            let start = index
            var end = index
            var gap = 0
            index += 1

            while index < foregroundCounts.count {
                if foregroundCounts[index] > 0 {
                    end = index
                    gap = 0
                    index += 1
                    continue
                }

                gap += 1
                if gap > mergeGap {
                    break
                }

                index += 1
            }

            segments.append(GlyphSegmentationRange(start: start, endInclusive: end))
        }

        return segments
    }

    private static func dynamicForegroundThreshold(
        pointer: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Int {
        var minLuma = 255
        var maxLuma = 0

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let luma = Int(row[x * 4 + 2])
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
            }
        }

        let midpoint = (minLuma + maxLuma) / 2
        return max(110, midpoint)
    }
}
