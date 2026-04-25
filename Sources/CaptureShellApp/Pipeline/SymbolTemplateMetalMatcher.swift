import Foundation
import Metal

final class SymbolTemplateMetalMatcher: @unchecked Sendable {
    struct Match {
        let character: Character
        let confidence: Double
        let precision: Double
    }

    private struct PreparedTemplate {
        let character: Character
        let sourceOffset: UInt32
        let sourceWidth: UInt32
        let sourceHeight: UInt32
    }

    private struct CandidateMetadata {
        let segmentIndex: Int
        let character: Character
    }

    private struct MetalCandidate {
        var sourceOffset: UInt32
        var sourceWidth: UInt32
        var sourceHeight: UInt32
        var destinationWidth: UInt32
        var destinationHeight: UInt32
        var x0: UInt32
        var y0: UInt32
        var maskForeground: UInt32
    }

    private struct MetalScore {
        var intersection: UInt32
        var templateForeground: UInt32
        var unionCount: UInt32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    static func make() -> SymbolTemplateMetalMatcher? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        do {
            let library = try device.makeLibrary(source: metalSource, options: nil)
            guard let function = library.makeFunction(name: "scoreSymbolCandidates") else {
                return nil
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            return SymbolTemplateMetalMatcher(
                device: device,
                commandQueue: commandQueue,
                pipeline: pipeline
            )
        } catch {
            FileHandle.standardError.write(
                "[FontTemplate] symbol Metal matcher unavailable: \(error)\n".data(using: .utf8) ?? Data()
            )
            return nil
        }
    }

    private init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    func bestMatches(
        mask: BinaryMask,
        segments: [FontTemplateMatcher.Segment],
        templates: [Character: FontTemplate]
    ) -> [Match?]? {
        guard !segments.isEmpty, !templates.isEmpty else {
            return Array(repeating: nil, count: segments.count)
        }

        let prepared = prepareTemplates(templates)
        guard !prepared.templates.isEmpty, !prepared.sourceBytes.isEmpty else {
            return nil
        }

        let candidates = makeCandidates(
            mask: mask,
            segments: segments,
            templates: prepared.templates
        )
        guard !candidates.values.isEmpty else {
            return Array(repeating: nil, count: segments.count)
        }

        guard let scores = score(
            maskPixels: mask.pixels,
            maskWidth: mask.width,
            templateBytes: prepared.sourceBytes,
            candidates: candidates.values
        ) else {
            return nil
        }

        var best = Array<Match?>(repeating: nil, count: segments.count)
        for index in scores.indices {
            let score = scores[index]
            guard score.unionCount > 0, score.templateForeground > 0 else {
                continue
            }

            let metadata = candidates.metadata[index]
            let candidate = Match(
                character: metadata.character,
                confidence: Double(score.intersection) / Double(score.unionCount),
                precision: Double(score.intersection) / Double(score.templateForeground)
            )
            if isBetter(candidate, than: best[metadata.segmentIndex]) {
                best[metadata.segmentIndex] = candidate
            }
        }

        return best
    }

    private func prepareTemplates(
        _ templates: [Character: FontTemplate]
    ) -> (templates: [PreparedTemplate], sourceBytes: [UInt8]) {
        let sortedTemplates = templates.sorted { lhs, rhs in
            String(lhs.key) < String(rhs.key)
        }

        var prepared: [PreparedTemplate] = []
        prepared.reserveCapacity(sortedTemplates.count)
        var sourceBytes: [UInt8] = []

        for (character, template) in sortedTemplates {
            guard template.width > 0, template.height > 0 else {
                continue
            }
            let offset = sourceBytes.count
            sourceBytes.append(contentsOf: template.mask)
            prepared.append(
                PreparedTemplate(
                    character: character,
                    sourceOffset: UInt32(offset),
                    sourceWidth: UInt32(template.width),
                    sourceHeight: UInt32(template.height)
                )
            )
        }

        return (prepared, sourceBytes)
    }

    private func makeCandidates(
        mask: BinaryMask,
        segments: [FontTemplateMatcher.Segment],
        templates: [PreparedTemplate]
    ) -> (values: [MetalCandidate], metadata: [CandidateMetadata]) {
        let widthRatios: [Double] = [0.90, 1.00, 1.10, 1.20]
        let heightRatios: [Double] = [0.95, 1.00, 1.05]

        var values: [MetalCandidate] = []
        var metadata: [CandidateMetadata] = []
        values.reserveCapacity(segments.count * templates.count * widthRatios.count * heightRatios.count * 35)
        metadata.reserveCapacity(values.capacity)

        for (segmentIndex, segment) in segments.enumerated() {
            let yTop = segment.top
            let yBottom = segment.bottom
            if yBottom < yTop {
                continue
            }
            let segW = segment.width
            let segH = yBottom - yTop + 1
            let yCenter = (yTop + yBottom) / 2

            for template in templates {
                for wRatio in widthRatios {
                    let destinationWidth = max(4, Int(Double(segW) * wRatio))
                    if segment.start + destinationWidth > mask.width {
                        continue
                    }

                    for hRatio in heightRatios {
                        let destinationHeight = max(4, Int(Double(segH) * hRatio))
                        if destinationHeight > mask.height {
                            continue
                        }

                        for dy in -3...3 {
                            let y0 = yCenter - destinationHeight / 2 + dy
                            if y0 < 0 || y0 + destinationHeight > mask.height {
                                continue
                            }

                            for dx in -2...2 {
                                let x0 = segment.start + dx
                                if x0 < 0 || x0 + destinationWidth > mask.width {
                                    continue
                                }

                                values.append(
                                    MetalCandidate(
                                        sourceOffset: template.sourceOffset,
                                        sourceWidth: template.sourceWidth,
                                        sourceHeight: template.sourceHeight,
                                        destinationWidth: UInt32(destinationWidth),
                                        destinationHeight: UInt32(destinationHeight),
                                        x0: UInt32(x0),
                                        y0: UInt32(y0),
                                        maskForeground: UInt32(mask.foregroundCount(
                                            x: x0,
                                            y: y0,
                                            width: destinationWidth,
                                            height: destinationHeight
                                        ))
                                    )
                                )
                                metadata.append(
                                    CandidateMetadata(
                                        segmentIndex: segmentIndex,
                                        character: template.character
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return (values, metadata)
    }

    private func score(
        maskPixels: [UInt8],
        maskWidth: Int,
        templateBytes: [UInt8],
        candidates: [MetalCandidate]
    ) -> [MetalScore]? {
        guard let maskBuffer = makeBuffer(from: maskPixels),
              let templateBuffer = makeBuffer(from: templateBytes),
              let candidateBuffer = makeBuffer(from: candidates) else {
            return nil
        }

        let scoreLength = candidates.count * MemoryLayout<MetalScore>.stride
        guard let scoreBuffer = device.makeBuffer(length: scoreLength, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var maskWidthValue = UInt32(maskWidth)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBytes(&maskWidthValue, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBuffer(templateBuffer, offset: 0, index: 2)
        encoder.setBuffer(candidateBuffer, offset: 0, index: 3)
        encoder.setBuffer(scoreBuffer, offset: 0, index: 4)

        let threadsPerThreadgroup = MTLSize(
            width: min(max(1, pipeline.maxTotalThreadsPerThreadgroup), 128),
            height: 1,
            depth: 1
        )
        let grid = MTLSize(width: candidates.count, height: 1, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            if let error = commandBuffer.error {
                FileHandle.standardError.write(
                    "[FontTemplate] symbol Metal scoring failed: \(error)\n".data(using: .utf8) ?? Data()
                )
            }
            return nil
        }

        let pointer = scoreBuffer.contents().bindMemory(to: MetalScore.self, capacity: candidates.count)
        return Array(UnsafeBufferPointer(start: pointer, count: candidates.count))
    }

    private func makeBuffer<T>(from values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else {
                return nil
            }
            return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: .storageModeShared)
        }
    }

    private func isBetter(_ candidate: Match, than current: Match?) -> Bool {
        guard let current else {
            return true
        }

        let confidenceDelta = candidate.confidence - current.confidence
        if abs(confidenceDelta) <= FontTemplateMatcherConstants.jaccardTieThreshold {
            return candidate.precision > current.precision
        }

        return confidenceDelta > 0
    }

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Candidate {
        uint sourceOffset;
        uint sourceWidth;
        uint sourceHeight;
        uint destinationWidth;
        uint destinationHeight;
        uint x0;
        uint y0;
        uint maskForeground;
    };

    struct Score {
        uint intersection;
        uint templateForeground;
        uint unionCount;
    };

    kernel void scoreSymbolCandidates(
        device const uchar *mask [[buffer(0)]],
        constant uint &maskWidth [[buffer(1)]],
        device const uchar *templates [[buffer(2)]],
        device const Candidate *candidates [[buffer(3)]],
        device Score *scores [[buffer(4)]],
        uint id [[thread_position_in_grid]]
    ) {
        Candidate candidate = candidates[id];
        uint intersection = 0;
        uint templateForeground = 0;

        const float xRatio = float(candidate.sourceWidth) / float(candidate.destinationWidth);
        const float yRatio = float(candidate.sourceHeight) / float(candidate.destinationHeight);

        for (uint dy = 0; dy < candidate.destinationHeight; dy++) {
            const float sourceY = (float(dy) + 0.5f) * yRatio - 0.5f;
            const int y0 = clamp(int(floor(sourceY)), 0, int(candidate.sourceHeight) - 1);
            const int y1 = clamp(y0 + 1, 0, int(candidate.sourceHeight) - 1);
            const float yFrac = clamp(sourceY - float(y0), 0.0f, 1.0f);

            for (uint dx = 0; dx < candidate.destinationWidth; dx++) {
                const float sourceX = (float(dx) + 0.5f) * xRatio - 0.5f;
                const int x0 = clamp(int(floor(sourceX)), 0, int(candidate.sourceWidth) - 1);
                const int x1 = clamp(x0 + 1, 0, int(candidate.sourceWidth) - 1);
                const float xFrac = clamp(sourceX - float(x0), 0.0f, 1.0f);

                const uint topLeftIndex = candidate.sourceOffset + uint(y0) * candidate.sourceWidth + uint(x0);
                const uint topRightIndex = candidate.sourceOffset + uint(y0) * candidate.sourceWidth + uint(x1);
                const uint bottomLeftIndex = candidate.sourceOffset + uint(y1) * candidate.sourceWidth + uint(x0);
                const uint bottomRightIndex = candidate.sourceOffset + uint(y1) * candidate.sourceWidth + uint(x1);

                const float p00 = float(templates[topLeftIndex]);
                const float p01 = float(templates[topRightIndex]);
                const float p10 = float(templates[bottomLeftIndex]);
                const float p11 = float(templates[bottomRightIndex]);
                const float top = p00 * (1.0f - xFrac) + p01 * xFrac;
                const float bottom = p10 * (1.0f - xFrac) + p11 * xFrac;
                const float value = top * (1.0f - yFrac) + bottom * yFrac;

                if (value >= 0.5f) {
                    templateForeground += 1;
                    const uint maskIndex = (candidate.y0 + dy) * maskWidth + candidate.x0 + dx;
                    if (mask[maskIndex] == 1) {
                        intersection += 1;
                    }
                }
            }
        }

        scores[id].intersection = intersection;
        scores[id].templateForeground = templateForeground;
        scores[id].unionCount = candidate.maskForeground + templateForeground - intersection;
    }
    """
}
