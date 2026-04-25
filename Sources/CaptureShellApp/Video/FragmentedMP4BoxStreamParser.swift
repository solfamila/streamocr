import Foundation

enum FragmentedMP4ParserError: Error, LocalizedError {
    case invalidBoxHeader
    case invalidBoxSize(type: String, size: UInt64)
    case missingVideoTrack
    case missingAVCConfiguration
    case unsupportedAVCConfiguration(String)
    case invalidFragment(String)

    var errorDescription: String? {
        switch self {
        case .invalidBoxHeader:
            return "Invalid MP4 box header."
        case let .invalidBoxSize(type, size):
            return "Invalid MP4 box size \(size) for \(type)."
        case .missingVideoTrack:
            return "Fragmented MP4 init segment did not contain a video track."
        case .missingAVCConfiguration:
            return "Fragmented MP4 init segment did not contain H.264 avcC configuration."
        case let .unsupportedAVCConfiguration(message):
            return "Unsupported H.264 avcC configuration: \(message)"
        case let .invalidFragment(message):
            return "Invalid fragmented MP4 media fragment: \(message)"
        }
    }
}

struct FragmentedMP4Box {
    let type: String
    let data: Data
    let headerSize: Int

    var payloadOffset: Int {
        headerSize
    }

    var payloadRange: Range<Int> {
        headerSize..<data.count
    }
}

final class FragmentedMP4BoxStreamParser {
    private static let maximumBufferedBytes = 16 * 1024 * 1024

    private var buffer = Data()

    func append(_ data: Data, onBox: (FragmentedMP4Box) throws -> Void) throws {
        buffer.append(data)

        while true {
            guard buffer.count >= 8 else {
                try validateBufferedByteCount()
                return
            }

            let smallSize = buffer.mp4UInt32(at: 0)
            let type = buffer.mp4ASCIIString(offset: 4, length: 4)
            let boxSize: UInt64
            let headerSize: Int

            if smallSize == 1 {
                guard buffer.count >= 16 else {
                    return
                }
                boxSize = buffer.mp4UInt64(at: 8)
                headerSize = 16
            } else {
                boxSize = UInt64(smallSize)
                headerSize = 8
            }

            guard boxSize >= UInt64(headerSize) else {
                throw FragmentedMP4ParserError.invalidBoxSize(type: type, size: boxSize)
            }
            guard boxSize <= UInt64(Int.max) else {
                throw FragmentedMP4ParserError.invalidBoxSize(type: type, size: boxSize)
            }

            let intBoxSize = Int(boxSize)
            guard intBoxSize <= Self.maximumBufferedBytes else {
                throw FragmentedMP4ParserError.invalidBoxSize(type: type, size: boxSize)
            }
            guard buffer.count >= intBoxSize else {
                try validateBufferedByteCount()
                return
            }

            let boxData = buffer.subdata(in: 0..<intBoxSize)
            buffer.removeSubrange(0..<intBoxSize)

            try onBox(
                FragmentedMP4Box(
                    type: type,
                    data: boxData,
                    headerSize: headerSize
                )
            )
        }
    }

    private func validateBufferedByteCount() throws {
        if buffer.count > Self.maximumBufferedBytes {
            throw FragmentedMP4ParserError.invalidFragment(
                "buffered partial box exceeded \(Self.maximumBufferedBytes) bytes"
            )
        }
    }
}

extension Data {
    func mp4UInt8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func mp4UInt16(at offset: Int) -> UInt16 {
        (UInt16(mp4UInt8(at: offset)) << 8) |
            UInt16(mp4UInt8(at: offset + 1))
    }

    func mp4UInt24(at offset: Int) -> UInt32 {
        (UInt32(mp4UInt8(at: offset)) << 16) |
            (UInt32(mp4UInt8(at: offset + 1)) << 8) |
            UInt32(mp4UInt8(at: offset + 2))
    }

    func mp4UInt32(at offset: Int) -> UInt32 {
        (UInt32(mp4UInt8(at: offset)) << 24) |
            (UInt32(mp4UInt8(at: offset + 1)) << 16) |
            (UInt32(mp4UInt8(at: offset + 2)) << 8) |
            UInt32(mp4UInt8(at: offset + 3))
    }

    func mp4Int32(at offset: Int) -> Int32 {
        Int32(bitPattern: mp4UInt32(at: offset))
    }

    func mp4UInt64(at offset: Int) -> UInt64 {
        (UInt64(mp4UInt32(at: offset)) << 32) |
            UInt64(mp4UInt32(at: offset + 4))
    }

    func mp4ASCIIString(offset: Int, length: Int) -> String {
        String(bytes: self[(startIndex + offset)..<(startIndex + offset + length)], encoding: .ascii) ?? ""
    }

    func mp4Subdata(_ range: Range<Int>) -> Data {
        subdata(in: range)
    }
}

func fragmentedMP4ChildBoxes(in data: Data, range: Range<Int>) throws -> [FragmentedMP4Box] {
    var boxes: [FragmentedMP4Box] = []
    var offset = range.lowerBound

    while offset + 8 <= range.upperBound {
        let smallSize = data.mp4UInt32(at: offset)
        let type = data.mp4ASCIIString(offset: offset + 4, length: 4)
        let boxSize: UInt64
        let headerSize: Int

        if smallSize == 1 {
            guard offset + 16 <= range.upperBound else {
                throw FragmentedMP4ParserError.invalidBoxHeader
            }
            boxSize = data.mp4UInt64(at: offset + 8)
            headerSize = 16
        } else {
            boxSize = UInt64(smallSize)
            headerSize = 8
        }

        guard boxSize >= UInt64(headerSize), boxSize <= UInt64(Int.max) else {
            throw FragmentedMP4ParserError.invalidBoxSize(type: type, size: boxSize)
        }

        let end = offset + Int(boxSize)
        guard end <= range.upperBound else {
            throw FragmentedMP4ParserError.invalidBoxSize(type: type, size: boxSize)
        }

        boxes.append(
            FragmentedMP4Box(
                type: type,
                data: data.mp4Subdata(offset..<end),
                headerSize: headerSize
            )
        )
        offset = end
    }

    return boxes
}
