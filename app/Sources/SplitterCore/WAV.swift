import Foundation

public struct SampleFormat: Equatable, Hashable, Sendable {
    public var isFloat: Bool
    /// Container size in bits: 16, 24 or 32.
    public var bits: Int

    public init(isFloat: Bool, bits: Int) {
        self.isFloat = isFloat
        self.bits = bits
    }

    public var bytes: Int { bits / 8 }
    public var label: String { isFloat ? "32-bit float" : "\(bits)-bit" }

    public static let int16 = SampleFormat(isFloat: false, bits: 16)
    public static let int24 = SampleFormat(isFloat: false, bits: 24)
    public static let int32 = SampleFormat(isFloat: false, bits: 32)
    public static let float32 = SampleFormat(isFloat: true, bits: 32)
}

public enum WavError: LocalizedError {
    case notWav(URL)
    case unsupported(URL, String)
    case io(URL, String)

    public var errorDescription: String? {
        switch self {
        case .notWav(let u): return "\(u.lastPathComponent) is not a WAV file."
        case .unsupported(let u, let why): return "\(u.lastPathComponent): \(why)."
        case .io(let u, let why): return "\(u.lastPathComponent): \(why)."
        }
    }
}

public struct WavInfo: Sendable {
    public let url: URL
    public let format: SampleFormat
    public let channels: Int
    public let sampleRate: Int
    public let dataOffset: UInt64
    public let frameCount: Int64
    public let fileSize: UInt64

    public var frameBytes: Int { channels * format.bytes }

    public func isCompatible(with other: WavInfo) -> Bool {
        format == other.format && channels == other.channels && sampleRate == other.sampleRate
    }

    /// Parses the RIFF/RF64 header. Tolerates the broken size fields that
    /// recorders leave behind when a take is interrupted.
    public static func read(_ url: URL) throws -> WavInfo {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw WavError.io(url, String(cString: strerror(errno))) }
        defer { close(fd) }

        var st = stat()
        fstat(fd, &st)
        let fileSize = UInt64(st.st_size)

        func bytes(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: count)
            return pread(fd, &buf, count, off_t(offset)) == count ? buf : nil
        }
        func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func le32(_ b: [UInt8], _ o: Int) -> UInt64 {
            UInt64(b[o]) | UInt64(b[o + 1]) << 8 | UInt64(b[o + 2]) << 16 | UInt64(b[o + 3]) << 24
        }
        func tag(_ b: [UInt8], _ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }

        guard let head = bytes(0, 12), ["RIFF", "RF64", "BW64"].contains(tag(head, 0)), tag(head, 8) == "WAVE" else {
            throw WavError.notWav(url)
        }

        var offset: UInt64 = 12
        var ds64DataSize: UInt64?
        var fmt: (format: SampleFormat, channels: Int, rate: Int)?

        while let h = bytes(offset, 8) {
            let id = tag(h, 0)
            let size = le32(h, 4)
            let body = offset + 8
            switch id {
            case "ds64":
                if let b = bytes(body, 16) { ds64DataSize = le32(b, 8) | le32(b, 12) << 32 }
            case "fmt ":
                guard size >= 16, let b = bytes(body, Int(min(size, 40))) else { throw WavError.notWav(url) }
                var formatTag = le16(b, 0)
                let channels = le16(b, 2)
                let rate = Int(le32(b, 4))
                let blockAlign = le16(b, 12)
                let bits = le16(b, 14)
                if formatTag == 0xFFFE, b.count >= 26 { formatTag = le16(b, 24) }
                let format: SampleFormat
                switch (formatTag, bits) {
                case (1, 16), (1, 24), (1, 32): format = SampleFormat(isFloat: false, bits: bits)
                case (3, 32): format = .float32
                default: throw WavError.unsupported(url, "unsupported sample format (tag \(formatTag), \(bits)-bit)")
                }
                guard channels > 0, rate > 0, blockAlign == channels * format.bytes else {
                    throw WavError.unsupported(url, "inconsistent format header")
                }
                fmt = (format, channels, rate)
            case "data":
                guard let fmt else { throw WavError.notWav(url) }
                let remaining = fileSize > body ? fileSize - body : 0
                var dataSize = size == 0xFFFF_FFFF ? (ds64DataSize ?? remaining) : size
                if dataSize == 0 || dataSize > remaining { dataSize = remaining }
                let frameBytes = UInt64(fmt.channels * fmt.format.bytes)
                return WavInfo(url: url, format: fmt.format, channels: fmt.channels, sampleRate: fmt.rate,
                               dataOffset: body, frameCount: Int64(dataSize / frameBytes), fileSize: fileSize)
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        throw WavError.notWav(url)
    }
}

/// Streaming WAV writer. Reserves a JUNK chunk so the file can be promoted to
/// RF64 on finish if it grows past 4 GB.
public final class WavWriter {
    public let url: URL
    public let format: SampleFormat
    public let channels: Int
    public let sampleRate: Int

    private var fd: Int32
    private var dataBytes: UInt64 = 0
    private let dataSizeOffset: Int

    public init(url: URL, format: SampleFormat, channels: Int, sampleRate: Int) throws {
        self.url = url
        self.format = format
        self.channels = channels
        self.sampleRate = sampleRate

        let formatTag: UInt16 = format.isFloat ? 3 : 1
        let blockAlign = channels * format.bytes
        var header = Data()
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func putTag(_ s: String) { header.append(contentsOf: Array(s.utf8)) }

        putTag("RIFF"); put32(0); putTag("WAVE")
        putTag("JUNK"); put32(28); header.append(Data(count: 28))
        let extensible = channels > 2
        putTag("fmt "); put32(extensible ? 40 : 16)
        put16(extensible ? 0xFFFE : formatTag)
        put16(UInt16(channels))
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * blockAlign))
        put16(UInt16(blockAlign))
        put16(UInt16(format.bits))
        if extensible {
            put16(22); put16(UInt16(format.bits)); put32(0)
            put16(formatTag)
            header.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        putTag("data")
        dataSizeOffset = header.count
        put32(0)

        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw WavError.io(url, String(cString: strerror(errno))) }
        try header.withUnsafeBytes { try writeAll($0.baseAddress!, $0.count) }
    }

    deinit { if fd >= 0 { close(fd) } }

    private func writeAll(_ p: UnsafeRawPointer, _ count: Int) throws {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, p + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw WavError.io(url, String(cString: strerror(errno)))
            }
            done += n
        }
    }

    public func write(_ p: UnsafeRawPointer, count: Int) throws {
        try writeAll(p, count)
        dataBytes += UInt64(count)
    }

    public func finish() throws {
        if dataBytes & 1 == 1 {
            var pad: UInt8 = 0
            try writeAll(&pad, 1)
        }
        let riffSize = UInt64(dataSizeOffset) + 4 + dataBytes + (dataBytes & 1) - 8

        func patch(_ bytes: [UInt8], at offset: Int) throws {
            guard pwrite(fd, bytes, bytes.count, off_t(offset)) == bytes.count else {
                throw WavError.io(url, String(cString: strerror(errno)))
            }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

        if riffSize <= 0xFFFF_FFFF {
            try patch(le(UInt32(riffSize)), at: 4)
            try patch(le(UInt32(dataBytes)), at: dataSizeOffset)
        } else {
            let frames = dataBytes / UInt64(channels * format.bytes)
            try patch(Array("RF64".utf8) + le(UInt32.max), at: 0)
            try patch(Array("ds64".utf8) + le(UInt32(28)) + le(riffSize) + le(dataBytes) + le(frames) + le(UInt32(0)), at: 12)
            try patch(le(UInt32.max), at: dataSizeOffset)
        }
        close(fd)
        fd = -1
    }

    /// Closes and removes the partially written file.
    public func abort() {
        if fd >= 0 { close(fd); fd = -1 }
        try? FileManager.default.removeItem(at: url)
    }
}

public enum PCM {
    /// Interleaved little-endian samples → floats in -1...1. `count` is in samples.
    public static func decode(_ src: UnsafeRawPointer, format: SampleFormat, count: Int, into dst: UnsafeMutablePointer<Float>) {
        if format.isFloat {
            for i in 0..<count { dst[i] = src.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
            return
        }
        switch format.bits {
        case 16:
            for i in 0..<count { dst[i] = Float(src.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
        case 24:
            let b = src.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let o = i * 3
                let v = Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(Int8(bitPattern: b[o + 2])) << 16
                dst[i] = Float(v) / 8_388_608
            }
        default:
            for i in 0..<count { dst[i] = Float(src.loadUnaligned(fromByteOffset: i * 4, as: Int32.self)) / 2_147_483_648 }
        }
    }

    /// Floats → interleaved little-endian samples. 16-bit output gets TPDF dither.
    public static func encode(_ src: UnsafePointer<Float>, count: Int, format: SampleFormat,
                              into dst: UnsafeMutableRawPointer, rng: inout UInt32) {
        if format.isFloat {
            for i in 0..<count { dst.storeBytes(of: src[i], toByteOffset: i * 4, as: Float.self) }
            return
        }
        switch format.bits {
        case 16:
            for i in 0..<count {
                rng = rng &* 1_664_525 &+ 1_013_904_223
                let r1 = Double(rng >> 8) / 16_777_216
                rng = rng &* 1_664_525 &+ 1_013_904_223
                let r2 = Double(rng >> 8) / 16_777_216
                let v = (Double(src[i]) * 32768 + r1 - r2).rounded()
                dst.storeBytes(of: Int16(max(-32768, min(32767, v))), toByteOffset: i * 2, as: Int16.self)
            }
        case 24:
            let b = dst.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let v = Int32(max(-8_388_608, min(8_388_607, (Double(src[i]) * 8_388_608).rounded())))
                let o = i * 3
                b[o] = UInt8(truncatingIfNeeded: v)
                b[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                b[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
        default:
            for i in 0..<count {
                let v = Int32(max(-2_147_483_648, min(2_147_483_647, (Double(src[i]) * 2_147_483_648).rounded())))
                dst.storeBytes(of: v, toByteOffset: i * 4, as: Int32.self)
            }
        }
    }
}

public enum Timecode {
    public static func format(frames: Int64, rate: Int) -> String {
        let ms = Int64((Double(frames) / Double(max(rate, 1)) * 1000).rounded())
        return String(format: "%lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Accepts "ss", "mm:ss" or "h:mm:ss", each with optional decimals.
    public static func parse(_ text: String, rate: Int) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            seconds = seconds * 60 + v
        }
        return Int64((seconds * Double(rate)).rounded())
    }

    public static func short(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
