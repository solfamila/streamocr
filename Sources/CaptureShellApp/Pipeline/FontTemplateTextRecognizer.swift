import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum FontTemplateMatcherConstants {
    static let maskBinarizationThreshold: UInt8 = 128
    static let diagnosticForegroundPixelThreshold = 20
    static let templateTargetGlyphHeightRatio: CGFloat = 0.72
    static let jaccardTieThreshold = 0.035
}

/// Deterministic text recognizer that matches a binarized ROI against
/// Core Text–rendered templates of the target UI font.
///
/// The same template-matching path handles both supported OCR regions:
/// numeric position cells use digit templates, and symbol cells use uppercase
/// letter templates. There is intentionally no Vision/Core ML fallback.
///
/// Design:
/// * At init time we record the preferred font name and a list of fallbacks.
/// * Templates are rendered lazily per input-height, then cached.
/// * For each frame we compute column foreground counts, cut the ROI into
///   contiguous ink segments, classify wide segments into N equal-width sub-pieces
///   based on the median glyph advance, and resample each glyph template to the
///   sub-segment's bounding box before comparing Jaccard overlap with a precision tie-breaker. A separate
///   narrow-segment pool holds separators so commas can't undercut numeric glyphs.
final class FontTemplateTextRecognizer: OCRTextRecognizing, @unchecked Sendable {
    struct Options: Sendable {
        private static let appleSDGothicNeoFonts = [
            "AppleSDGothicNeo-SemiBold",
            "AppleSDGothicNeo-Medium",
            "AppleSDGothicNeo-Bold",
            "AppleSDGothicNeo-Regular",
            "AppleSDGothicNeo-ExtraBold",
            "AppleSDGothicNeo-Heavy",
            "HelveticaNeue",
            "Helvetica"
        ]

        private static let microsoftSansSerifFonts = [
            "MicrosoftSansSerif",
            "Microsoft Sans Serif",
            "ArialMT",
            "Arial-BoldMT",
            "HelveticaNeue",
            "Helvetica"
        ]

        var preferredFontNames: [String]
        /// Full-width characters that are candidates for ordinary glyph segments.
        var glyphCharacters: String
        /// Narrow characters (comma, period) that are candidates for separator segments.
        /// Kept disjoint from `glyphCharacters` so the matcher can't pick a skinny
        /// comma over a real numeric glyph just because its bounding box happens to fit.
        var separatorCharacters: String
        var minimumSegmentAreaRatio: Double
        var minimumGlyphHeightRatioForNarrowSegment: Double
        var splitWideSegments: Bool
        var mergeGap: Int

        static let numericCell = Options(
            preferredFontNames: appleSDGothicNeoFonts,
            glyphCharacters: "0123456789",
            separatorCharacters: ",.",
            minimumSegmentAreaRatio: 0.010,
            // Apple SD Gothic Neo's "1" is much narrower than the other digits.
            // Width-only separator detection misclassifies it as comma/period, so
            // narrow full-height segments must stay in the numeric glyph pool.
            minimumGlyphHeightRatioForNarrowSegment: 0.58,
            splitWideSegments: true,
            // Digits are tightly spaced but always separated by ≥1 black column after
            // binarization; keeping mergeGap=0 prevents "4" + "7" from being glued into
            // a single wide segment.
            mergeGap: 0
        )

        static let symbolCell = Options(
            preferredFontNames: microsoftSansSerifFonts,
            glyphCharacters: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            separatorCharacters: "",
            minimumSegmentAreaRatio: 0.006,
            minimumGlyphHeightRatioForNarrowSegment: 0.58,
            splitWideSegments: false,
            mergeGap: 0
        )
    }

    private struct TemplateCacheKey: Hashable {
        let region: OCRRegionKind
        let height: Int
    }

    private let numericOptions: Options
    private let symbolOptions: Options
    private let templateCacheLock = NSLock()
    private var templateCache: [TemplateCacheKey: FontTemplateSet] = [:]
    private let diagnosticLock = NSLock()
    private var diagnosticDumpDone = false
    private let symbolMetalMatcher: SymbolTemplateMetalMatcher?

    init(
        numericOptions: Options = .numericCell,
        symbolOptions: Options = .symbolCell,
        symbolMetalMatcher: SymbolTemplateMetalMatcher? = SymbolTemplateMetalMatcher.make()
    ) {
        self.numericOptions = numericOptions
        self.symbolOptions = symbolOptions
        self.symbolMetalMatcher = symbolMetalMatcher
    }

    func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition {
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let options = options(for: region)
        guard height > 8, let templates = templates(for: height, region: region, options: options) else {
            return OCRTextRecognition(rawText: "", confidence: 0)
        }

        guard let mask = binarizedMask(from: pixelBuffer) else {
            return OCRTextRecognition(rawText: "", confidence: 0)
        }

        maybeDumpDiagnostics(mask: mask, templates: templates)

        let decoded: FontTemplateMatcher.Decoded
        if region == .manualSymbolCell,
           let symbolMetalMatcher,
           let metalDecoded = FontTemplateMatcher.decodeSymbolWithMetal(
            mask: mask,
            templates: templates,
            options: options,
            matcher: symbolMetalMatcher
           ) {
            decoded = metalDecoded
        } else {
            decoded = FontTemplateMatcher.decode(mask: mask, templates: templates, options: options)
        }
        guard !decoded.characters.isEmpty else {
            return OCRTextRecognition(rawText: "", confidence: 0)
        }

        // Confidence = worst per-glyph score (conservative).
        let confidence = decoded.perGlyphConfidences.min() ?? 0

        return OCRTextRecognition(
            rawText: String(decoded.characters),
            confidence: confidence
        )
    }

    private func options(for region: OCRRegionKind) -> Options {
        switch region {
        case .manualCell:
            numericOptions
        case .manualSymbolCell:
            symbolOptions
        }
    }

    private func templates(
        for height: Int,
        region: OCRRegionKind,
        options: Options
    ) -> FontTemplateSet? {
        templateCacheLock.lock()
        defer { templateCacheLock.unlock() }

        let key = TemplateCacheKey(region: region, height: height)
        if let cached = templateCache[key] {
            return cached
        }

        guard let set = FontTemplateSet.make(targetHeight: height, options: options) else {
            return nil
        }

        templateCache[key] = set
        return set
    }

    private func binarizedMask(from pixelBuffer: CVPixelBuffer) -> BinaryMask? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else {
            return nil
        }

        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                // OCRRegionPreprocessor writes BGRA 0/255 post-binarize; use red channel.
                let luma = row[x * 4 + 2]
                pixels[y * width + x] = luma >= FontTemplateMatcherConstants.maskBinarizationThreshold ? 1 : 0
            }
        }

        return BinaryMask(width: width, height: height, pixels: pixels)
    }

    // MARK: - Diagnostics

    /// If the environment variable `FONT_TEMPLATE_DIAG_DIR` is set, dump templates
    /// and the first non-empty binarized mask to that directory as PNGs. Runs
    /// once per recognizer instance so repeated frames don't spam the disk.
    private func maybeDumpDiagnostics(mask: BinaryMask, templates: FontTemplateSet) {
        guard let dir = ProcessInfo.processInfo.environment["FONT_TEMPLATE_DIAG_DIR"],
              !dir.isEmpty else {
            return
        }

        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        if diagnosticDumpDone { return }
        // Wait until we see actual content so the dumped mask is meaningful.
        if mask.foregroundCount() < FontTemplateMatcherConstants.diagnosticForegroundPixelThreshold { return }
        diagnosticDumpDone = true

        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Write a plain-text summary of what the matcher is actually using.
        let glyphWidths = templates.glyphTemplates
            .sorted { String($0.key) < String($1.key) }
            .map { "\($0.key)=\($0.value.width)×\($0.value.height)" }
            .joined(separator: ", ")
        let separatorWidths = templates.separatorTemplates
            .map { "\($0.key)=\($0.value.width)×\($0.value.height)" }
            .joined(separator: ", ")
        let info = """
        resolved_font: \(templates.fontName)
        bitmap_height: \(templates.bitmapHeight)
        median_advance: \(templates.medianAdvanceWidth)
        glyph_templates: \(glyphWidths)
        separator_templates: \(separatorWidths)
        mask_size: \(mask.width)x\(mask.height) fg=\(mask.foregroundCount())
        """
        try? info.write(
            to: dirURL.appendingPathComponent("font-info.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Dump the input mask.
        FontTemplateDiagnosticsIO.writeMaskAsPNG(
            mask.pixels,
            width: mask.width,
            height: mask.height,
            to: dirURL.appendingPathComponent("input-mask.png")
        )

        // Dump each rendered template.
        let allTemplates = templates.glyphTemplates.merging(
            templates.separatorTemplates,
            uniquingKeysWith: { lhs, _ in lhs }
        )
        for (character, template) in allTemplates {
            let safeName = FontTemplateDiagnosticsIO.safeFileName(for: character)
            FontTemplateDiagnosticsIO.writeMaskAsPNG(
                template.mask,
                width: template.width,
                height: template.height,
                to: dirURL.appendingPathComponent("template-\(safeName).png")
            )
        }

        FileHandle.standardError.write(
            "[FontTemplate] diagnostics written to \(dirURL.path)\n".data(using: .utf8) ?? Data()
        )
    }
}

// MARK: - Mask & template types

struct BinaryMask: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]
    private let foregroundIntegral: [Int]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.foregroundIntegral = Self.makeForegroundIntegral(width: width, height: height, pixels: pixels)
    }

    func foregroundCount() -> Int {
        foregroundIntegral.last ?? 0
    }

    func foregroundCount(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) -> Int {
        guard rectWidth > 0, rectHeight > 0 else {
            return 0
        }
        let stride = width + 1
        let x0 = x
        let y0 = y
        let x1 = x + rectWidth
        let y1 = y + rectHeight
        return foregroundIntegral[y1 * stride + x1]
            - foregroundIntegral[y0 * stride + x1]
            - foregroundIntegral[y1 * stride + x0]
            + foregroundIntegral[y0 * stride + x0]
    }

    private static func makeForegroundIntegral(width: Int, height: Int, pixels: [UInt8]) -> [Int] {
        guard width > 0, height > 0 else {
            return [0]
        }
        let stride = width + 1
        var integral = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowTotal = 0
            for x in 0..<width {
                if pixels[y * width + x] == 1 {
                    rowTotal += 1
                }
                integral[(y + 1) * stride + (x + 1)] = integral[y * stride + (x + 1)] + rowTotal
            }
        }
        return integral
    }
}

struct FontTemplate: Sendable {
    let character: Character
    /// Tight bounding-box pixel mask (0/1) of the rendered glyph.
    let mask: [UInt8]
    /// Width of `mask` in pixels.
    let width: Int
    /// Height of `mask` in pixels.
    let height: Int
    /// Y offset of the top of the mask relative to the template bitmap top.
    let yOffset: Int
    /// Advance width reported by Core Text for this glyph at the rendered size.
    let advanceWidth: CGFloat
    /// Total foreground pixel count inside `mask`.
    let foregroundCount: Int
}

struct FontTemplateSet: Sendable {
    let fontName: String
    let bitmapHeight: Int
    /// Primary glyph templates (0-9 for numeric cells, A-Z for symbol cells).
    let glyphTemplates: [Character: FontTemplate]
    /// Separator templates (comma, period by default).
    let separatorTemplates: [Character: FontTemplate]
    /// Median advance width across primary glyph templates; used to decide whether a
    /// composite segment spans multiple glyphs and to classify segments as
    /// glyph-wide or separator-wide.
    let medianAdvanceWidth: CGFloat
    /// Median tight-bounding-box height across primary glyph templates; used to keep
    /// skinny full-height digits such as Apple SD Gothic Neo "1" out of the
    /// separator pool.
    let medianGlyphHeight: CGFloat

    var templates: [Character: FontTemplate] {
        glyphTemplates.merging(separatorTemplates, uniquingKeysWith: { lhs, _ in lhs })
    }

    static func make(targetHeight: Int, options: FontTemplateTextRecognizer.Options) -> FontTemplateSet? {
        // Calibrate font size once so that the reference glyph's
        // bounding-box height is ~0.72 * targetHeight (matches Apple SD Gothic Neo's
        // tabular numerals when rendered on-screen against the trading panel).
        let target = CGFloat(targetHeight) * FontTemplateMatcherConstants.templateTargetGlyphHeightRatio

        guard
            let (font, fontName) = resolveFont(from: options.preferredFontNames)
        else {
            return nil
        }

        let referenceCharacter = options.glyphCharacters.first ?? "0"
        let pointSize = calibratePointSize(
            font: font,
            referenceCharacter: referenceCharacter,
            targetGlyphHeight: target
        )
        let calibrated = CTFontCreateCopyWithAttributes(font, pointSize, nil, nil)

        var glyphRendered: [Character: FontTemplate] = [:]
        var separatorRendered: [Character: FontTemplate] = [:]
        var glyphAdvances: [CGFloat] = []
        var glyphHeights: [CGFloat] = []

        for character in options.glyphCharacters {
            guard let template = renderTemplate(character: character, font: calibrated, bitmapHeight: targetHeight) else {
                continue
            }
            glyphRendered[character] = template
            glyphAdvances.append(template.advanceWidth)
            glyphHeights.append(CGFloat(template.height))
        }
        for character in options.separatorCharacters {
            guard let template = renderTemplate(character: character, font: calibrated, bitmapHeight: targetHeight) else {
                continue
            }
            separatorRendered[character] = template
        }

        guard !glyphRendered.isEmpty else {
            return nil
        }

        let sortedAdvances = glyphAdvances.sorted()
        let median = sortedAdvances.isEmpty
            ? CGFloat(targetHeight) * 0.5
            : sortedAdvances[sortedAdvances.count / 2]
        let sortedHeights = glyphHeights.sorted()
        let medianHeight = sortedHeights.isEmpty
            ? CGFloat(targetHeight) * FontTemplateMatcherConstants.templateTargetGlyphHeightRatio
            : sortedHeights[sortedHeights.count / 2]

        return FontTemplateSet(
            fontName: fontName,
            bitmapHeight: targetHeight,
            glyphTemplates: glyphRendered,
            separatorTemplates: separatorRendered,
            medianAdvanceWidth: median,
            medianGlyphHeight: medianHeight
        )
    }

    private static func resolveFont(from preferredNames: [String]) -> (CTFont, String)? {
        for name in preferredNames {
            let candidate = CTFontCreateWithName(name as CFString, 64, nil)
            let resolvedName = CTFontCopyPostScriptName(candidate) as String
            if resolvedName.caseInsensitiveCompare(name) == .orderedSame {
                FontTemplateDiagnosticsIO.logFontResolutionOnce(
                    requested: name,
                    resolved: resolvedName,
                    substituted: false
                )
                return (candidate, resolvedName)
            } else {
                FontTemplateDiagnosticsIO.logFontResolutionOnce(
                    requested: name,
                    resolved: resolvedName,
                    substituted: true
                )
            }
        }
        // Last-resort: fall back to whatever the system gives us for the first preferred
        // name. CTFontCreateWithName will substitute a default when the requested name
        // is unavailable, so this is always non-nil but callers should still log the
        // substitution.
        let firstName = preferredNames.first ?? "Helvetica"
        let fallback = CTFontCreateWithName(firstName as CFString, 64, nil)
        let resolvedName = CTFontCopyPostScriptName(fallback) as String
        FontTemplateDiagnosticsIO.logFontResolutionOnce(
            requested: firstName,
            resolved: resolvedName,
            substituted: true
        )
        return (fallback, resolvedName)
    }

    private static func calibratePointSize(
        font: CTFont,
        referenceCharacter: Character,
        targetGlyphHeight: CGFloat
    ) -> CGFloat {
        var unichars = Array(String(referenceCharacter).utf16)
        var glyphs: [CGGlyph] = Array(repeating: 0, count: unichars.count)
        guard !unichars.isEmpty else {
            return max(4, targetGlyphHeight)
        }

        guard CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count) else {
            return max(4, targetGlyphHeight)
        }

        var boundingRects: [CGRect] = Array(repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &boundingRects, glyphs.count)
        let referenceHeight = boundingRects.map(\.height).max() ?? 0
        let referenceSize = CTFontGetSize(font)
        guard referenceHeight > 0 else {
            return max(4, targetGlyphHeight)
        }
        return max(4, referenceSize * targetGlyphHeight / referenceHeight)
    }

    private static func renderTemplate(
        character: Character,
        font: CTFont,
        bitmapHeight: Int
    ) -> FontTemplate? {
        let scalars = Array(character.unicodeScalars)
        guard !scalars.isEmpty else { return nil }

        var unichars: [UniChar] = []
        for scalar in scalars {
            for code in scalar.utf16 {
                unichars.append(code)
            }
        }

        var glyphs: [CGGlyph] = Array(repeating: 0, count: unichars.count)
        let mapped = CTFontGetGlyphsForCharacters(font, unichars, &glyphs, unichars.count)
        guard mapped else { return nil }

        var advances: [CGSize] = Array(repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let advance = advances.reduce(0) { $0 + $1.width }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let bitmapWidth = max(4, Int(ceil(advance)) + 6)
        let targetHeight = bitmapHeight

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: bitmapWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: bitmapWidth, height: targetHeight))
        context.setFillColor(gray: 1, alpha: 1)

        // Baseline positioning: put the glyph's baseline at `descent` from the bottom,
        // then shift so the glyph is vertically centered on the target bitmap height.
        let totalFontHeight = ascent + descent
        let extraSpace = CGFloat(targetHeight) - totalFontHeight
        let baselineY = descent + (extraSpace / 2)
        let positions: [CGPoint] = [CGPoint(x: 3, y: baselineY)]

        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)

        guard let data = context.data else {
            return nil
        }
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        // CGBitmapContext stores rows top-down in memory even though the drawing
        // coordinate system is y-up. So buffer row 0 == top of the rendered glyph,
        // which matches the input mask (CVPixelBuffer, also top-down). No flip needed —
        // an earlier version of this code flipped, which produced upside-down templates
        // and crushed match confidence against right-side-up UI pixels.
        var rawMask = [UInt8](repeating: 0, count: bitmapWidth * targetHeight)
        for y in 0..<targetHeight {
            let srcRow = bytes.advanced(by: y * bitmapWidth)
            for x in 0..<bitmapWidth {
                rawMask[y * bitmapWidth + x] = srcRow[x] >= FontTemplateMatcherConstants.maskBinarizationThreshold ? 1 : 0
            }
        }

        // Tight bounding box.
        var minX = bitmapWidth, maxX = -1, minY = targetHeight, maxY = -1
        for y in 0..<targetHeight {
            for x in 0..<bitmapWidth where rawMask[y * bitmapWidth + x] == 1 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let tightWidth = maxX - minX + 1
        let tightHeight = maxY - minY + 1
        var tightMask = [UInt8](repeating: 0, count: tightWidth * tightHeight)
        var count = 0
        for y in 0..<tightHeight {
            for x in 0..<tightWidth {
                let value = rawMask[(minY + y) * bitmapWidth + (minX + x)]
                tightMask[y * tightWidth + x] = value
                if value == 1 { count += 1 }
            }
        }

        return FontTemplate(
            character: character,
            mask: tightMask,
            width: tightWidth,
            height: tightHeight,
            yOffset: minY,
            advanceWidth: advance,
            foregroundCount: count
        )
    }
}

// MARK: - Matcher

enum FontTemplateMatcher {
    struct Decoded {
        let characters: [Character]
        let perGlyphConfidences: [Double]
    }

    static func decode(
        mask: BinaryMask,
        templates: FontTemplateSet,
        options: FontTemplateTextRecognizer.Options
    ) -> Decoded {
        let rawSegments = foregroundSegments(in: mask, mergeGap: options.mergeGap)
        guard !rawSegments.isEmpty else {
            return Decoded(characters: [], perGlyphConfidences: [])
        }

        let medianAdvance = templates.medianAdvanceWidth
        let medianGlyphHeight = templates.medianGlyphHeight
        var characters: [Character] = []
        var confidences: [Double] = []

        // Walk every raw segment. Wide segments (area spanning multiple glyphs) are
        // pre-sliced into N equal-width sub-segments. Then each sub-segment is
        // matched against the appropriate template pool by resampling templates to
        // the segment's own bounding box — this is what makes the matcher robust
        // to small size mismatches between rendered templates and on-screen ink.
        for segment in rawSegments {
            let segmentArea = Double(segment.area) / Double(max(1, mask.width * mask.height))
            guard segmentArea >= options.minimumSegmentAreaRatio else {
                continue
            }

            let segmentWidth = segment.endInclusive - segment.start + 1
            let glyphWidthFraction = medianAdvance > 0 ? Double(segmentWidth) / Double(medianAdvance) : 0
            let glyphHeightFraction = medianGlyphHeight > 0 ? Double(segment.height) / Double(medianGlyphHeight) : 0

            if glyphWidthFraction < 0.5,
               glyphHeightFraction < options.minimumGlyphHeightRatioForNarrowSegment,
               !templates.separatorTemplates.isEmpty {
                // Narrow, short segment — treat as a separator. Narrow but tall
                // segments are usually Apple SD Gothic Neo's skinny "1".
                if let match = bestMatchForSegment(
                    mask: mask,
                    segment: segment,
                    pool: templates.separatorTemplates
                ) {
                    characters.append(match.character)
                    confidences.append(match.confidence)
                }
                continue
            }

            let tileCount = options.splitWideSegments ? max(1, Int(glyphWidthFraction.rounded())) : 1
            let tiles = equalWidthSlice(segment: segment, tileCount: tileCount, mask: mask)
            for tile in tiles {
                if let match = bestMatchForSegment(
                    mask: mask,
                    segment: tile,
                    pool: templates.glyphTemplates
                ) {
                    characters.append(match.character)
                    confidences.append(match.confidence)
                }
            }
        }

        return Decoded(characters: characters, perGlyphConfidences: confidences)
    }

    static func decodeSymbolWithMetal(
        mask: BinaryMask,
        templates: FontTemplateSet,
        options: FontTemplateTextRecognizer.Options,
        matcher: SymbolTemplateMetalMatcher
    ) -> Decoded? {
        guard !options.splitWideSegments, templates.separatorTemplates.isEmpty else {
            return nil
        }

        let rawSegments = foregroundSegments(in: mask, mergeGap: options.mergeGap)
        guard !rawSegments.isEmpty else {
            return Decoded(characters: [], perGlyphConfidences: [])
        }

        let filteredSegments = rawSegments.filter { segment in
            let segmentArea = Double(segment.area) / Double(max(1, mask.width * mask.height))
            return segmentArea >= options.minimumSegmentAreaRatio
        }
        guard !filteredSegments.isEmpty else {
            return Decoded(characters: [], perGlyphConfidences: [])
        }

        guard let matches = matcher.bestMatches(
            mask: mask,
            segments: filteredSegments,
            templates: templates.glyphTemplates
        ) else {
            return nil
        }

        var characters: [Character] = []
        var confidences: [Double] = []
        characters.reserveCapacity(matches.count)
        confidences.reserveCapacity(matches.count)

        for match in matches {
            guard let match else {
                continue
            }
            characters.append(match.character)
            confidences.append(match.confidence)
        }

        return Decoded(characters: characters, perGlyphConfidences: confidences)
    }

    // MARK: Segmentation

    struct Segment {
        let start: Int
        let endInclusive: Int
        let area: Int
        let top: Int
        let bottom: Int

        var width: Int { endInclusive - start + 1 }
        var height: Int { bottom >= top ? bottom - top + 1 : 0 }
    }

    private static func foregroundSegments(in mask: BinaryMask, mergeGap: Int) -> [Segment] {
        var columnCounts = [Int](repeating: 0, count: mask.width)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.pixels[y * mask.width + x] == 1 {
                columnCounts[x] += 1
            }
        }

        var segments: [Segment] = []
        var index = 0
        while index < mask.width {
            while index < mask.width, columnCounts[index] == 0 { index += 1 }
            guard index < mask.width else { break }
            let start = index
            var end = index
            var gap = 0
            index += 1
            while index < mask.width {
                if columnCounts[index] > 0 {
                    end = index
                    gap = 0
                } else {
                    gap += 1
                    if gap > mergeGap { break }
                }
                index += 1
            }
            let area = (start...end).reduce(0) { $0 + columnCounts[$1] }
            var top = mask.height
            var bottom = -1
            for x in start...end where columnCounts[x] > 0 {
                for y in 0..<mask.height where mask.pixels[y * mask.width + x] == 1 {
                    if y < top { top = y }
                    if y > bottom { bottom = y }
                }
            }
            segments.append(
                Segment(
                    start: start,
                    endInclusive: end,
                    area: area,
                    top: top,
                    bottom: bottom
                )
            )
        }
        return segments
    }

    /// Slice a wide segment into `tileCount` equal-width contiguous pieces. Area is
    /// recomputed per piece from the mask.
    private static func equalWidthSlice(
        segment: Segment,
        tileCount: Int,
        mask: BinaryMask
    ) -> [Segment] {
        if tileCount <= 1 {
            return [segment]
        }
        let start = segment.start
        let end = segment.endInclusive
        let span = Double(end - start + 1)
        let piece = span / Double(tileCount)
        var result: [Segment] = []
        for i in 0..<tileCount {
            let s = start + Int((Double(i) * piece).rounded())
            var e = start + Int((Double(i + 1) * piece).rounded()) - 1
            e = min(e, end)
            if s > e { continue }
            var area = 0
            var top = mask.height
            var bottom = -1
            for x in s...e {
                var column = 0
                for y in 0..<mask.height where mask.pixels[y * mask.width + x] == 1 {
                    column += 1
                    if y < top { top = y }
                    if y > bottom { bottom = y }
                }
                area += column
            }
            result.append(
                Segment(
                    start: s,
                    endInclusive: e,
                    area: area,
                    top: top,
                    bottom: bottom
                )
            )
        }
        return result
    }

    // MARK: Template-resampled matching

    private struct Match {
        let character: Character
        let confidence: Double
        let precision: Double
    }

    private struct MatchQuality {
        let jaccard: Double
        let precision: Double
    }

    private struct TemplatePoint {
        let x: Int
        let y: Int
    }

    private struct ResizedTemplateMask {
        let width: Int
        let height: Int
        let foregroundPoints: [TemplatePoint]

        var foregroundCount: Int { foregroundPoints.count }
    }

    /// For a single-glyph segment, compute its tight bounding box, then for each
    /// candidate template try a small grid of (width, height, dx, dy) perturbations.
    /// Ranking is primarily Jaccard, with precision used only for near ties. This
    /// avoids larger templates such as "6" absorbing a true "5" when UI anti-aliasing
    /// thickens the captured strokes, without letting tiny template subsets win.
    private static func bestMatchForSegment(
        mask: BinaryMask,
        segment: Segment,
        pool: [Character: FontTemplate]
    ) -> Match? {
        let yTop = segment.top
        let yBottom = segment.bottom
        if yBottom < yTop { return nil }
        let segW = segment.width
        let segH = yBottom - yTop + 1
        let yCenter = (yTop + yBottom) / 2

        // Candidate dimensions — test a few widths and heights near the segment bbox
        // to absorb small size mismatches between rendered templates and on-screen ink.
        let widthRatios: [Double] = [0.90, 1.00, 1.10, 1.20]
        let heightRatios: [Double] = [0.95, 1.00, 1.05]

        var best: Match?

        for (character, template) in pool {
            for wRatio in widthRatios {
                let w = max(4, Int(Double(segW) * wRatio))
                // The resampled template must fit inside the mask.
                if segment.start + w > mask.width { continue }
                for hRatio in heightRatios {
                    let h = max(4, Int(Double(segH) * hRatio))
                    if h > mask.height { continue }

                    // Resample template to (w, h) once; reuse across (dx, dy) loop.
                    let resized = resizeTemplateForeground(
                        source: template.mask,
                        srcW: template.width,
                        srcH: template.height,
                        dstW: w,
                        dstH: h
                    )

                    for dy in -3...3 {
                        let y0 = yCenter - h / 2 + dy
                        if y0 < 0 || y0 + h > mask.height { continue }

                        for dx in -2...2 {
                            let x0 = segment.start + dx
                            if x0 < 0 || x0 + w > mask.width { continue }

                            let quality = matchQualityInWindow(
                                mask: mask,
                                x0: x0,
                                y0: y0,
                                template: resized,
                                width: w,
                                height: h
                            )
                            let candidate = Match(
                                character: character,
                                confidence: quality.jaccard,
                                precision: quality.precision
                            )
                            if isBetter(candidate, than: best) {
                                best = candidate
                            }
                        }
                    }
                }
            }
        }

        return best
    }

    private static func isBetter(_ candidate: Match, than current: Match?) -> Bool {
        guard let current else {
            return true
        }

        let confidenceDelta = candidate.confidence - current.confidence
        if abs(confidenceDelta) <= FontTemplateMatcherConstants.jaccardTieThreshold {
            return candidate.precision > current.precision
        }

        return confidenceDelta > 0
    }

    /// Bilinear-interpolated resize of a 0/1 mask, re-binarized at 0.5.
    /// Return foreground coordinates directly so each candidate window scores only
    /// template ink pixels instead of rescanning the full rectangle.
    private static func resizeTemplateForeground(
        source: [UInt8],
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int
    ) -> ResizedTemplateMask {
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else {
            return ResizedTemplateMask(width: dstW, height: dstH, foregroundPoints: [])
        }

        if srcW == dstW && srcH == dstH {
            var points: [TemplatePoint] = []
            points.reserveCapacity(source.count)
            for y in 0..<srcH {
                for x in 0..<srcW where source[y * srcW + x] == 1 {
                    points.append(TemplatePoint(x: x, y: y))
                }
            }
            return ResizedTemplateMask(width: dstW, height: dstH, foregroundPoints: points)
        }

        var points: [TemplatePoint] = []
        points.reserveCapacity(dstW * dstH / 2)

        let xRatio = Double(srcW) / Double(dstW)
        let yRatio = Double(srcH) / Double(dstH)

        for dy in 0..<dstH {
            let srcYf = (Double(dy) + 0.5) * yRatio - 0.5
            let y0 = max(0, min(srcH - 1, Int(floor(srcYf))))
            let y1 = max(0, min(srcH - 1, y0 + 1))
            let yFrac = max(0, min(1, srcYf - Double(y0)))
            for dx in 0..<dstW {
                let srcXf = (Double(dx) + 0.5) * xRatio - 0.5
                let x0 = max(0, min(srcW - 1, Int(floor(srcXf))))
                let x1 = max(0, min(srcW - 1, x0 + 1))
                let xFrac = max(0, min(1, srcXf - Double(x0)))

                let p00 = Double(source[y0 * srcW + x0])
                let p01 = Double(source[y0 * srcW + x1])
                let p10 = Double(source[y1 * srcW + x0])
                let p11 = Double(source[y1 * srcW + x1])
                let top = p00 * (1 - xFrac) + p01 * xFrac
                let bot = p10 * (1 - xFrac) + p11 * xFrac
                let value = top * (1 - yFrac) + bot * yFrac
                if value >= 0.5 {
                    points.append(TemplatePoint(x: dx, y: dy))
                }
            }
        }
        return ResizedTemplateMask(width: dstW, height: dstH, foregroundPoints: points)
    }

    /// Overlap quality between mask[x0..<x0+w, y0..<y0+h] and a flat template
    /// block. Jaccard is the primary shape score; precision penalizes extra template
    /// strokes that do not exist in the input glyph.
    private static func matchQualityInWindow(
        mask: BinaryMask,
        x0: Int,
        y0: Int,
        template: ResizedTemplateMask,
        width: Int,
        height: Int
    ) -> MatchQuality {
        var intersection = 0
        for point in template.foregroundPoints {
            if mask.pixels[(y0 + point.y) * mask.width + x0 + point.x] == 1 {
                intersection += 1
            }
        }
        let templateForeground = template.foregroundCount
        let maskForeground = mask.foregroundCount(x: x0, y: y0, width: width, height: height)
        let union = maskForeground + templateForeground - intersection
        guard union > 0, templateForeground > 0 else {
            return MatchQuality(jaccard: 0, precision: 0)
        }

        let jaccard = Double(intersection) / Double(union)
        let precision = Double(intersection) / Double(templateForeground)
        return MatchQuality(jaccard: jaccard, precision: precision)
    }
}

// MARK: - Diagnostics I/O

/// Tiny helper with file-scope state so we can log each unique (requested, resolved)
/// pair at most once, and write 0/1 masks as actual PNGs for visual inspection.
enum FontTemplateDiagnosticsIO {
    private static let stateLock = NSLock()
    // Protected by `stateLock`; `nonisolated(unsafe)` silences Swift 6 global-var
    // concurrency diagnostics since we're manually synchronizing access.
    nonisolated(unsafe) private static var loggedPairs = Set<String>()

    static func logFontResolutionOnce(requested: String, resolved: String, substituted: Bool) {
        let key = "\(requested)|\(resolved)|\(substituted ? "subst" : "ok")"
        stateLock.lock()
        let inserted = loggedPairs.insert(key).inserted
        stateLock.unlock()
        guard inserted else { return }

        let marker = substituted ? "SUBSTITUTED" : "ok"
        let message = "[FontTemplate] font \"\(requested)\" -> \"\(resolved)\" [\(marker)]\n"
        FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
    }

    static func safeFileName(for character: Character) -> String {
        switch character {
        case ",": return "comma"
        case ".": return "period"
        default: return String(character)
        }
    }

    static func writeMaskAsPNG(_ mask: [UInt8], width: Int, height: Int, to url: URL) {
        guard width > 0, height > 0, mask.count >= width * height else { return }

        // Let Core Graphics own the backing buffer so we don't have lifetime
        // concerns with a Swift array that gets released before the CGImage is used.
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }

        guard let basePointer = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerRow = context.bytesPerRow
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            let srcRowStart = y * width
            for x in 0..<width {
                basePointer[rowStart + x] = mask[srcRowStart + x] == 1 ? 255 : 0
            }
        }

        guard let image = context.makeImage() else { return }

        let typeIdentifier: CFString
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, *) {
            typeIdentifier = UTType.png.identifier as CFString
        } else {
            typeIdentifier = "public.png" as CFString
        }
        #else
        typeIdentifier = "public.png" as CFString
        #endif

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            typeIdentifier,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
