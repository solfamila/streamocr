import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct FragmentedMP4DecodeSummary: Sendable {
    let frameCount: Int
    let firstFrameElapsedSeconds: Double?
    let firstMediaElapsedSeconds: Double?
}

final class FragmentedMP4VideoToolboxDecoder: @unchecked Sendable {
    private let boxParser = FragmentedMP4BoxStreamParser()
    private let nominalFrameRate: Double?
    private let onFrame: @Sendable (VideoFrame) -> Void
    private let start = Date()
    private let stateLock = NSLock()
    private let appendLock = NSLock()

    private var videoTrackConfiguration: FragmentedMP4VideoTrackConfiguration?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var pendingMoof: FragmentedMP4Box?
    private var decodedFrameCount = 0
    private var firstFrameElapsedSeconds: Double?
    private var firstMediaElapsedSeconds: Double?

    init(nominalFrameRate: Double? = nil, onFrame: @escaping @Sendable (VideoFrame) -> Void) {
        self.nominalFrameRate = nominalFrameRate
        self.onFrame = onFrame
    }

    func append(_ data: Data) throws {
        appendLock.lock()
        defer { appendLock.unlock() }
        try boxParser.append(data) { [weak self] box in
            try self?.handle(box)
        }
    }

    func finish() {
        appendLock.lock()
        defer { appendLock.unlock() }
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
    }

    func summary() -> FragmentedMP4DecodeSummary {
        stateLock.lock()
        defer { stateLock.unlock() }
        return FragmentedMP4DecodeSummary(
            frameCount: decodedFrameCount,
            firstFrameElapsedSeconds: firstFrameElapsedSeconds,
            firstMediaElapsedSeconds: firstMediaElapsedSeconds
        )
    }

    private func handle(_ box: FragmentedMP4Box) throws {
        switch box.type {
        case "moov":
            let configuration = try FragmentedMP4InitSegmentParser.parseVideoTrackConfiguration(from: box)
            videoTrackConfiguration = configuration
            formatDescription = try Self.makeFormatDescription(from: configuration.h264Configuration)
            try makeDecompressionSessionIfNeeded()
        case "moof":
            pendingMoof = box
        case "mdat":
            guard let pendingMoof, let videoTrackConfiguration else {
                return
            }
            stateLock.lock()
            firstMediaElapsedSeconds = firstMediaElapsedSeconds ?? Date().timeIntervalSince(start)
            stateLock.unlock()
            let samples = try FragmentedMP4FragmentParser.videoSamples(
                moof: pendingMoof,
                mdat: box,
                configuration: videoTrackConfiguration
            )
            self.pendingMoof = nil
            try makeDecompressionSessionIfNeeded()
            for sample in samples {
                try decode(sample)
            }
            if let decompressionSession {
                // Keep live OCR real-time: never let VideoToolbox build an
                // unbounded queue of decoded frames while OCR is still working.
                VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            }
        default:
            break
        }
    }

    private func makeDecompressionSessionIfNeeded() throws {
        guard decompressionSession == nil else {
            return
        }
        guard let formatDescription else {
            return
        }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: fragmentedMP4VideoToolboxOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw FragmentedMP4ParserError.invalidFragment("VTDecompressionSessionCreate failed with status \(status)")
        }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
    }

    private func decode(_ sample: FragmentedMP4MediaSample) throws {
        guard let decompressionSession, let formatDescription else {
            throw FragmentedMP4ParserError.invalidFragment("missing VideoToolbox session")
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else {
            throw FragmentedMP4ParserError.invalidFragment("CMBlockBufferCreateWithMemoryBlock failed with status \(createStatus)")
        }

        try sample.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
            guard replaceStatus == noErr else {
                throw FragmentedMP4ParserError.invalidFragment("CMBlockBufferReplaceDataBytes failed with status \(replaceStatus)")
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(sample.duration), timescale: CMTimeScale(sample.timescale)),
            presentationTimeStamp: CMTime(value: CMTimeValue(sample.presentationTime), timescale: CMTimeScale(sample.timescale)),
            decodeTimeStamp: CMTime(value: CMTimeValue(sample.decodeTime), timescale: CMTimeScale(sample.timescale))
        )
        var sampleSize = sample.data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw FragmentedMP4ParserError.invalidFragment("CMSampleBufferCreateReady failed with status \(sampleStatus)")
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard decodeStatus == noErr else {
            throw FragmentedMP4ParserError.invalidFragment("VTDecompressionSessionDecodeFrame failed with status \(decodeStatus)")
        }
    }

    fileprivate func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime
    ) {
        guard status == noErr, let pixelBuffer = imageBuffer else {
            return
        }

        stateLock.lock()
        decodedFrameCount += 1
        firstFrameElapsedSeconds = firstFrameElapsedSeconds ?? Date().timeIntervalSince(start)
        stateLock.unlock()
        onFrame(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                nominalFrameRate: nominalFrameRate
            )
        )
    }

    private static func makeFormatDescription(
        from configuration: FragmentedMP4H264Configuration
    ) throws -> CMVideoFormatDescription {
        let allocatedParameterSets = configuration.parameterSets.map { parameterSet in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: parameterSet.count)
            _ = parameterSet.copyBytes(to: UnsafeMutableBufferPointer(start: pointer, count: parameterSet.count))
            return pointer
        }
        defer {
            for pointer in allocatedParameterSets {
                pointer.deallocate()
            }
        }

        var parameterSetPointers = allocatedParameterSets.map { UnsafePointer($0) }
        var parameterSetSizes = configuration.parameterSets.map(\.count)
        var description: CMVideoFormatDescription?

        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetPointers.count,
            parameterSetPointers: &parameterSetPointers,
            parameterSetSizes: &parameterSetSizes,
            nalUnitHeaderLength: Int32(configuration.nalUnitLengthSize),
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw FragmentedMP4ParserError.unsupportedAVCConfiguration(
                "CMVideoFormatDescriptionCreateFromH264ParameterSets failed with status \(status)"
            )
        }
        return description
    }
}

private let fragmentedMP4VideoToolboxOutputCallback: VTDecompressionOutputCallback = {
    decompressionOutputRefCon,
    _,
    status,
    _,
    imageBuffer,
    presentationTimeStamp,
    _
    in

    guard let decompressionOutputRefCon else {
        return
    }

    let decoder = Unmanaged<FragmentedMP4VideoToolboxDecoder>
        .fromOpaque(decompressionOutputRefCon)
        .takeUnretainedValue()
    decoder.handleDecodedFrame(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp
    )
}

private struct FragmentedMP4H264Configuration {
    let nalUnitLengthSize: Int
    let parameterSets: [Data]
}

private struct FragmentedMP4VideoTrackConfiguration {
    let trackID: UInt32
    let timescale: UInt32
    let h264Configuration: FragmentedMP4H264Configuration
    let defaultSampleDuration: UInt32?
    let defaultSampleSize: UInt32?
    let defaultSampleFlags: UInt32?
}

private struct FragmentedMP4TrackDefaults {
    let defaultSampleDuration: UInt32?
    let defaultSampleSize: UInt32?
    let defaultSampleFlags: UInt32?
}

private enum FragmentedMP4InitSegmentParser {
    static func parseVideoTrackConfiguration(
        from moov: FragmentedMP4Box
    ) throws -> FragmentedMP4VideoTrackConfiguration {
        let moovChildren = try fragmentedMP4ChildBoxes(in: moov.data, range: moov.payloadRange)
        let trackDefaults = try parseTrackDefaults(from: moovChildren)

        for trak in moovChildren where trak.type == "trak" {
            if let track = try parseTrack(from: trak, defaultsByTrackID: trackDefaults) {
                return track
            }
        }

        throw FragmentedMP4ParserError.missingVideoTrack
    }

    private static func parseTrackDefaults(
        from moovChildren: [FragmentedMP4Box]
    ) throws -> [UInt32: FragmentedMP4TrackDefaults] {
        guard let mvex = moovChildren.first(where: { $0.type == "mvex" }) else {
            return [:]
        }

        let mvexChildren = try fragmentedMP4ChildBoxes(in: mvex.data, range: mvex.payloadRange)
        var result: [UInt32: FragmentedMP4TrackDefaults] = [:]

        for trex in mvexChildren where trex.type == "trex" {
            guard trex.data.count >= trex.payloadOffset + 24 else {
                continue
            }
            let offset = trex.payloadOffset
            let trackID = trex.data.mp4UInt32(at: offset + 4)
            result[trackID] = FragmentedMP4TrackDefaults(
                defaultSampleDuration: nonZero(trex.data.mp4UInt32(at: offset + 12)),
                defaultSampleSize: nonZero(trex.data.mp4UInt32(at: offset + 16)),
                defaultSampleFlags: nonZero(trex.data.mp4UInt32(at: offset + 20))
            )
        }

        return result
    }

    private static func parseTrack(
        from trak: FragmentedMP4Box,
        defaultsByTrackID: [UInt32: FragmentedMP4TrackDefaults]
    ) throws -> FragmentedMP4VideoTrackConfiguration? {
        let children = try fragmentedMP4ChildBoxes(in: trak.data, range: trak.payloadRange)
        let trackID = children.first(where: { $0.type == "tkhd" }).flatMap(parseTrackID)
        guard let mdia = children.first(where: { $0.type == "mdia" }) else {
            return nil
        }

        let mdiaChildren = try fragmentedMP4ChildBoxes(in: mdia.data, range: mdia.payloadRange)
        guard
            mdiaChildren.first(where: { $0.type == "hdlr" }).flatMap(parseHandlerType) == "vide",
            let trackID,
            let timescale = mdiaChildren.first(where: { $0.type == "mdhd" }).flatMap(parseTimescale),
            let avcConfiguration = try parseAVCConfiguration(from: mdiaChildren)
        else {
            return nil
        }

        let defaults = defaultsByTrackID[trackID]
        return FragmentedMP4VideoTrackConfiguration(
            trackID: trackID,
            timescale: timescale,
            h264Configuration: avcConfiguration,
            defaultSampleDuration: defaults?.defaultSampleDuration,
            defaultSampleSize: defaults?.defaultSampleSize,
            defaultSampleFlags: defaults?.defaultSampleFlags
        )
    }

    private static func parseTrackID(from tkhd: FragmentedMP4Box) -> UInt32? {
        guard tkhd.data.count > tkhd.payloadOffset else {
            return nil
        }
        let version = tkhd.data.mp4UInt8(at: tkhd.payloadOffset)
        let trackIDOffset = tkhd.payloadOffset + (version == 1 ? 20 : 12)
        guard tkhd.data.count >= trackIDOffset + 4 else {
            return nil
        }
        return tkhd.data.mp4UInt32(at: trackIDOffset)
    }

    private static func parseTimescale(from mdhd: FragmentedMP4Box) -> UInt32? {
        guard mdhd.data.count > mdhd.payloadOffset else {
            return nil
        }
        let version = mdhd.data.mp4UInt8(at: mdhd.payloadOffset)
        let timescaleOffset = mdhd.payloadOffset + (version == 1 ? 20 : 12)
        guard mdhd.data.count >= timescaleOffset + 4 else {
            return nil
        }
        return nonZero(mdhd.data.mp4UInt32(at: timescaleOffset))
    }

    private static func parseHandlerType(from hdlr: FragmentedMP4Box) -> String? {
        let handlerOffset = hdlr.payloadOffset + 8
        guard hdlr.data.count >= handlerOffset + 4 else {
            return nil
        }
        return hdlr.data.mp4ASCIIString(offset: handlerOffset, length: 4)
    }

    private static func parseAVCConfiguration(
        from mdiaChildren: [FragmentedMP4Box]
    ) throws -> FragmentedMP4H264Configuration? {
        guard
            let minf = mdiaChildren.first(where: { $0.type == "minf" }),
            let stbl = try fragmentedMP4ChildBoxes(in: minf.data, range: minf.payloadRange)
                .first(where: { $0.type == "stbl" }),
            let stsd = try fragmentedMP4ChildBoxes(in: stbl.data, range: stbl.payloadRange)
                .first(where: { $0.type == "stsd" })
        else {
            return nil
        }

        let sampleEntryStart = stsd.payloadOffset + 8
        guard stsd.data.count >= sampleEntryStart else {
            return nil
        }

        let sampleEntries = try fragmentedMP4ChildBoxes(in: stsd.data, range: sampleEntryStart..<stsd.data.count)
        for entry in sampleEntries where entry.type == "avc1" || entry.type == "avc3" {
            let avcChildStart = entry.payloadOffset + 78
            guard entry.data.count >= avcChildStart else {
                continue
            }
            let entryChildren = try fragmentedMP4ChildBoxes(in: entry.data, range: avcChildStart..<entry.data.count)
            if let avcC = entryChildren.first(where: { $0.type == "avcC" }) {
                return try parseAVCC(avcC.data.mp4Subdata(avcC.payloadRange))
            }
        }

        throw FragmentedMP4ParserError.missingAVCConfiguration
    }

    private static func parseAVCC(_ data: Data) throws -> FragmentedMP4H264Configuration {
        guard data.count >= 7 else {
            throw FragmentedMP4ParserError.unsupportedAVCConfiguration("avcC is too short")
        }

        let nalUnitLengthSize = Int(data.mp4UInt8(at: 4) & 0x03) + 1
        guard nalUnitLengthSize == 4 else {
            throw FragmentedMP4ParserError.unsupportedAVCConfiguration(
                "expected 4-byte NAL lengths, got \(nalUnitLengthSize)"
            )
        }

        var offset = 6
        let spsCount = Int(data.mp4UInt8(at: 5) & 0x1f)
        var parameterSets: [Data] = []

        for _ in 0..<spsCount {
            guard offset + 2 <= data.count else {
                throw FragmentedMP4ParserError.unsupportedAVCConfiguration("truncated SPS length")
            }
            let length = Int(data.mp4UInt16(at: offset))
            offset += 2
            guard offset + length <= data.count else {
                throw FragmentedMP4ParserError.unsupportedAVCConfiguration("truncated SPS")
            }
            parameterSets.append(data.mp4Subdata(offset..<(offset + length)))
            offset += length
        }

        guard offset < data.count else {
            throw FragmentedMP4ParserError.unsupportedAVCConfiguration("missing PPS count")
        }
        let ppsCount = Int(data.mp4UInt8(at: offset))
        offset += 1

        for _ in 0..<ppsCount {
            guard offset + 2 <= data.count else {
                throw FragmentedMP4ParserError.unsupportedAVCConfiguration("truncated PPS length")
            }
            let length = Int(data.mp4UInt16(at: offset))
            offset += 2
            guard offset + length <= data.count else {
                throw FragmentedMP4ParserError.unsupportedAVCConfiguration("truncated PPS")
            }
            parameterSets.append(data.mp4Subdata(offset..<(offset + length)))
            offset += length
        }

        guard parameterSets.count >= 2 else {
            throw FragmentedMP4ParserError.unsupportedAVCConfiguration("expected SPS and PPS")
        }

        return FragmentedMP4H264Configuration(
            nalUnitLengthSize: nalUnitLengthSize,
            parameterSets: parameterSets
        )
    }
}

private struct FragmentedMP4MediaSample {
    let data: Data
    let decodeTime: UInt64
    let presentationTime: Int64
    let duration: UInt32
    let timescale: UInt32
}

private enum FragmentedMP4FragmentParser {
    static func videoSamples(
        moof: FragmentedMP4Box,
        mdat: FragmentedMP4Box,
        configuration: FragmentedMP4VideoTrackConfiguration
    ) throws -> [FragmentedMP4MediaSample] {
        let moofChildren = try fragmentedMP4ChildBoxes(in: moof.data, range: moof.payloadRange)
        var samples: [FragmentedMP4MediaSample] = []
        var pair = Data()
        pair.append(moof.data)
        pair.append(mdat.data)

        for traf in moofChildren where traf.type == "traf" {
            let trafChildren = try fragmentedMP4ChildBoxes(in: traf.data, range: traf.payloadRange)
            guard
                let tfhd = try trafChildren.first(where: { $0.type == "tfhd" }).flatMap(parseTFHD),
                tfhd.trackID == configuration.trackID
            else {
                continue
            }

            let baseDecodeTime = trafChildren.first(where: { $0.type == "tfdt" }).flatMap(parseTFDT) ?? 0
            let truns = try trafChildren
                .filter { $0.type == "trun" }
                .map(parseTRUN)

            var decodeTime = baseDecodeTime
            var implicitDataOffset = moof.data.count + mdat.payloadOffset

            for trun in truns {
                var sampleDataOffset = trun.dataOffset ?? implicitDataOffset
                for (index, sample) in trun.samples.enumerated() {
                    let sampleSize = sample.size ??
                        tfhd.defaultSampleSize ??
                        configuration.defaultSampleSize ??
                        (trun.samples.count == 1 ? UInt32(max(0, pair.count - sampleDataOffset)) : nil)
                    guard let sampleSize, sampleSize > 0 else {
                        throw FragmentedMP4ParserError.invalidFragment("missing video sample size")
                    }

                    let duration = sample.duration ??
                        tfhd.defaultSampleDuration ??
                        configuration.defaultSampleDuration ??
                        1
                    let compositionOffset = sample.compositionTimeOffset ?? 0
                    let start = sampleDataOffset
                    let end = start + Int(sampleSize)
                    guard start >= 0, end <= pair.count else {
                        throw FragmentedMP4ParserError.invalidFragment(
                            "video sample range \(start)..<\(end) exceeds fragment size \(pair.count)"
                        )
                    }

                    let presentationTime = Int64(decodeTime) + Int64(compositionOffset)
                    samples.append(
                        FragmentedMP4MediaSample(
                            data: pair.mp4Subdata(start..<end),
                            decodeTime: decodeTime,
                            presentationTime: presentationTime,
                            duration: duration,
                            timescale: configuration.timescale
                        )
                    )

                    sampleDataOffset = end
                    decodeTime += UInt64(duration)

                    if index == trun.samples.endIndex - 1 {
                        implicitDataOffset = sampleDataOffset
                    }
                }
            }
        }

        return samples
    }

    private static func parseTFHD(_ box: FragmentedMP4Box) throws -> TrackFragmentHeader {
        guard box.data.count >= box.payloadOffset + 8 else {
            throw FragmentedMP4ParserError.invalidFragment("tfhd is too short")
        }

        let flags = box.data.mp4UInt24(at: box.payloadOffset + 1)
        var offset = box.payloadOffset + 4
        let trackID = box.data.mp4UInt32(at: offset)
        offset += 4

        if flags & 0x000001 != 0 {
            offset += 8
        }
        if flags & 0x000002 != 0 {
            offset += 4
        }

        let defaultSampleDuration = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000008 != 0)
        let defaultSampleSize = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000010 != 0)
        let defaultSampleFlags = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000020 != 0)

        return TrackFragmentHeader(
            trackID: trackID,
            defaultSampleDuration: defaultSampleDuration,
            defaultSampleSize: defaultSampleSize,
            defaultSampleFlags: defaultSampleFlags
        )
    }

    private static func parseTFDT(_ box: FragmentedMP4Box) -> UInt64? {
        guard box.data.count > box.payloadOffset else {
            return nil
        }
        let version = box.data.mp4UInt8(at: box.payloadOffset)
        let offset = box.payloadOffset + 4
        if version == 1 {
            guard box.data.count >= offset + 8 else {
                return nil
            }
            return box.data.mp4UInt64(at: offset)
        }

        guard box.data.count >= offset + 4 else {
            return nil
        }
        return UInt64(box.data.mp4UInt32(at: offset))
    }

    private static func parseTRUN(_ box: FragmentedMP4Box) throws -> TrackRun {
        guard box.data.count >= box.payloadOffset + 8 else {
            throw FragmentedMP4ParserError.invalidFragment("trun is too short")
        }

        let version = box.data.mp4UInt8(at: box.payloadOffset)
        let flags = box.data.mp4UInt24(at: box.payloadOffset + 1)
        var offset = box.payloadOffset + 4
        let sampleCount = Int(box.data.mp4UInt32(at: offset))
        offset += 4

        var dataOffset: Int?
        if flags & 0x000001 != 0 {
            guard box.data.count >= offset + 4 else {
                throw FragmentedMP4ParserError.invalidFragment("truncated trun data offset")
            }
            dataOffset = Int(box.data.mp4Int32(at: offset))
            offset += 4
        }

        if flags & 0x000004 != 0 {
            guard box.data.count >= offset + 4 else {
                throw FragmentedMP4ParserError.invalidFragment("truncated trun first sample flags")
            }
            offset += 4
        }

        var samples: [TrackRunSample] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let duration = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000100 != 0)
            let size = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000200 != 0)
            _ = readOptionalUInt32(box.data, offset: &offset, enabled: flags & 0x000400 != 0)
            let compositionTimeOffset: Int32?
            if flags & 0x000800 != 0 {
                guard box.data.count >= offset + 4 else {
                    throw FragmentedMP4ParserError.invalidFragment("truncated trun composition offset")
                }
                compositionTimeOffset = version == 1 ?
                    box.data.mp4Int32(at: offset) :
                    Int32(bitPattern: box.data.mp4UInt32(at: offset))
                offset += 4
            } else {
                compositionTimeOffset = nil
            }
            samples.append(
                TrackRunSample(
                    duration: duration,
                    size: size,
                    compositionTimeOffset: compositionTimeOffset
                )
            )
        }

        return TrackRun(dataOffset: dataOffset, samples: samples)
    }

    private static func readOptionalUInt32(_ data: Data, offset: inout Int, enabled: Bool) -> UInt32? {
        guard enabled else {
            return nil
        }
        guard data.count >= offset + 4 else {
            return nil
        }
        defer { offset += 4 }
        return data.mp4UInt32(at: offset)
    }
}

private struct TrackFragmentHeader {
    let trackID: UInt32
    let defaultSampleDuration: UInt32?
    let defaultSampleSize: UInt32?
    let defaultSampleFlags: UInt32?
}

private struct TrackRun {
    let dataOffset: Int?
    let samples: [TrackRunSample]
}

private struct TrackRunSample {
    let duration: UInt32?
    let size: UInt32?
    let compositionTimeOffset: Int32?
}

private func nonZero(_ value: UInt32) -> UInt32? {
    value == 0 ? nil : value
}
