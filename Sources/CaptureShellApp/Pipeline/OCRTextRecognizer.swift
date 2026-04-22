import CoreVideo

struct OCRTextRecognition: Sendable {
    let rawText: String
    let confidence: Double
}

protocol OCRTextRecognizing: AnyObject, Sendable {
    func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition
}
