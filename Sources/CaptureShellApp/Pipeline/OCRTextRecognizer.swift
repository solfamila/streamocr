import CoreVideo
import Foundation
import Vision

struct OCRTextRecognition: Sendable {
    let rawText: String
    let confidence: Double
}

protocol OCRTextRecognizing: AnyObject, Sendable {
    func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition
}

final class VisionTextRecognizer: OCRTextRecognizing, @unchecked Sendable {
    private let requestByRegion: [OCRRegionKind: VNRecognizeTextRequest]

    init(requestByRegion: [OCRRegionKind: VNRecognizeTextRequest] = VisionTextRecognizer.makeRequests()) {
        self.requestByRegion = requestByRegion
    }

    func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition {
        guard let request = requestByRegion[region] else {
            return OCRTextRecognition(rawText: "", confidence: 0)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard
                let topObservation = observations.first,
                let topCandidate = topObservation.topCandidates(1).first
            else {
                return OCRTextRecognition(rawText: "", confidence: 0)
            }

            return OCRTextRecognition(
                rawText: topCandidate.string,
                confidence: Double(topCandidate.confidence)
            )
        } catch {
            return OCRTextRecognition(rawText: "", confidence: 0)
        }
    }

    private static func makeRequests() -> [OCRRegionKind: VNRecognizeTextRequest] {
        [
            .manualCell: makeRequest(),
            .manualSymbolCell: makeRequest()
        ]
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        return request
    }
}
