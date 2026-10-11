import Foundation

/// One take: a single WAV, or several parts the recorder split at the FAT32
/// file size limit, read as one continuous stream.
public final class Recording: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let parts: [WavInfo]
    public let format: SampleFormat
    public let channels: Int
    public let sampleRate: Int
    public let frameCount: Int64
    public let totalBytes: UInt64
    /// When the take was recorded, as far as the file timestamps tell: the
    /// earlier of the first part's creation and modification dates.
    public let created: Date?

    private let partStart: [Int64]
    private var fds: [Int32]
    private let lock = NSLock()

    public init(name: String, parts: [WavInfo]) {
        precondition(!parts.isEmpty)
        self.name = name
        self.parts = parts
        format = parts[0].format
        channels = parts[0].channels
        sampleRate = parts[0].sampleRate
        var starts: [Int64] = []
        var total: Int64 = 0
        for p in parts {
            starts.append(total)
            total += p.frameCount
        }
        partStart = starts
        frameCount = total
        totalBytes = parts.reduce(0) { $0 + $1.fileSize }
        fds = Array(repeating: -1, count: parts.count)
        let stamps = try? parts[0].url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        created = [stamps?.creationDate, stamps?.contentModificationDate].compactMap { $0 }.min()
    }

    /// Default name for exports: `yyyymmdd_-_name`, or just the name if the date is unknown.
    public var datedName: String {
        guard let created else { return name }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: created) + "_-_" + name
    }

    deinit { for fd in fds where fd >= 0 { close(fd) } }

    public var frameBytes: Int { channels * format.bytes }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
    public var folder: URL { parts[0].url.deletingLastPathComponent() }

    private func descriptor(_ index: Int) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if fds[index] >= 0 { return fds[index] }
        let fd = open(parts[index].url.path, O_RDONLY)
        guard fd >= 0 else { throw WavError.io(parts[index].url, String(cString: strerror(errno))) }
        fds[index] = fd
        return fd
    }

    /// Reads up to `count` interleaved frames starting at `frame`. Returns the
    /// number of frames read, which is only short at the end of the recording.
    public func read(frame: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        var frame = frame
        var done = 0
        let fb = frameBytes
        guard frame >= 0 else { return 0 }
        while done < count, frame < frameCount {
            guard let index = partStart.lastIndex(where: { $0 <= frame }) else { break }
            let part = parts[index]
            let local = frame - partStart[index]
            let n = Int(min(Int64(count - done), part.frameCount - local))
            if n <= 0 { break }
            let fd = try descriptor(index)
            var got = 0
            let want = n * fb
            while got < want {
                let r = pread(fd, buffer + done * fb + got, want - got, off_t(part.dataOffset) + off_t(local) * off_t(fb) + off_t(got))
                if r < 0 {
                    if errno == EINTR { continue }
                    throw WavError.io(part.url, String(cString: strerror(errno)))
                }
                if r == 0 { throw WavError.io(part.url, "unexpected end of file") }
                got += r
            }
            done += n
            frame += Int64(n)
        }
        return done
    }
}

public struct ScanResult {
    public var recordings: [Recording] = []
    public var skipped: [(url: URL, reason: String)] = []
}

public enum RecordingScanner {
    struct PartKey {
        var prefix: String
        var index: Int
        /// Names like UFX04_00: the number before the underscore is the take,
        /// so the suffix can only be a part number.
        var recorderStyle: Bool
    }

    static func partKey(_ url: URL) -> PartKey? {
        let base = url.deletingPathExtension().lastPathComponent
        guard let underscore = base.lastIndex(of: "_") else { return nil }
        let prefix = String(base[..<underscore])
        let digits = base[base.index(after: underscore)...]
        guard !prefix.isEmpty, (1...3).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(digits) else { return nil }
        let recorderStyle = digits.count == 2 && prefix.range(of: "^[A-Za-z]+[0-9]+$", options: .regularExpression) != nil
        return PartKey(prefix: prefix, index: index, recorderStyle: recorderStyle)
    }

    /// Parts of other recorders are only joined when the earlier part is big
    /// enough to plausibly have hit a file size limit.
    static let splitSizeThreshold: UInt64 = 1 << 30

    public static func scan(_ urls: [URL]) -> ScanResult {
        scan(urls, splitSizeThreshold: splitSizeThreshold)
    }

    static func scan(_ urls: [URL], splitSizeThreshold: UInt64) -> ScanResult {
        let fm = FileManager.default
        var result = ScanResult()
        var files: [URL] = []
        var seen = Set<String>()

        func isWav(_ u: URL) -> Bool { u.pathExtension.lowercased() == "wav" }
        func add(_ u: URL) {
            let s = u.standardizedFileURL
            if seen.insert(s.path).inserted { files.append(s) }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let f as URL in e {
                    if e.level > 3 { e.skipDescendants(); continue }
                    if isWav(f) { add(f) }
                }
            } else if isWav(url) {
                add(url)
                // A single dropped part pulls in the rest of its take.
                if let key = partKey(url),
                   let siblings = try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                              includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for s in siblings where isWav(s) && partKey(s)?.prefix.lowercased() == key.prefix.lowercased() { add(s) }
                }
            } else {
                result.skipped.append((url, "not a WAV file"))
            }
        }

        var groups: [String: [(info: WavInfo, key: PartKey)]] = [:]
        var takes: [(name: String, parts: [WavInfo])] = []

        for url in files {
            let info: WavInfo
            do { info = try WavInfo.read(url) } catch {
                result.skipped.append((url, error.localizedDescription))
                continue
            }
            guard info.frameCount > 0 else {
                result.skipped.append((url, "empty file"))
                continue
            }
            if let key = partKey(url) {
                groups[url.deletingLastPathComponent().path + "\u{0}" + key.prefix.lowercased(), default: []].append((info, key))
            } else {
                takes.append((url.deletingPathExtension().lastPathComponent, [info]))
            }
        }

        for members in groups.values {
            let sorted = members.sorted { $0.key.index < $1.key.index }
            var run = [sorted[0]]
            func flush() {
                let first = run[0]
                let name = run.count > 1 || first.key.recorderStyle
                    ? first.key.prefix : first.info.url.deletingPathExtension().lastPathComponent
                takes.append((name, run.map(\.info)))
            }
            for m in sorted.dropFirst() {
                let prev = run[run.count - 1]
                let continues = m.key.index == prev.key.index + 1 && m.info.isCompatible(with: prev.info)
                    && (m.key.recorderStyle || prev.info.fileSize >= splitSizeThreshold)
                if continues {
                    run.append(m)
                } else {
                    flush()
                    run = [m]
                }
            }
            flush()
        }

        result.recordings = takes
            .sorted { $0.parts[0].url.path.localizedStandardCompare($1.parts[0].url.path) == .orderedAscending }
            .map { Recording(name: $0.name, parts: $0.parts) }
        return result
    }
}

public enum Overview {
    /// Coarse per-channel peak envelope. Samples a short block per bin rather
    /// than reading every frame, so multi-gigabyte takes on an SD card show up
    /// in seconds. Calls `update` with the envelope so far and bins completed.
    public static func compute(_ rec: Recording, bins requested: Int = 1000,
                               isCancelled: () -> Bool, update: ([[Float]], Int) -> Void) {
        let total = rec.frameCount
        let ch = rec.channels
        guard total > 0 else { return }
        let bins = Int(min(Int64(requested), total))
        let perBin = total / Int64(bins)
        let budget = 64 << 20
        let block = Int(min(perBin, Int64(max(256, budget / (bins * rec.frameBytes)))))

        var peaks = [[Float]](repeating: [Float](repeating: 0, count: bins), count: ch)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: block * rec.frameBytes, alignment: 16)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: block * ch)
        defer { raw.deallocate(); samples.deallocate() }

        for b in 0..<bins {
            if isCancelled() { return }
            let start = Int64(b) * total / Int64(bins)
            let got = (try? rec.read(frame: start, count: block, into: raw)) ?? 0
            if got > 0 {
                PCM.decode(raw, format: rec.format, count: got * ch, into: samples)
                for c in 0..<ch {
                    var peak: Float = 0
                    var i = c
                    while i < got * ch {
                        peak = max(peak, abs(samples[i]))
                        i += ch
                    }
                    peaks[c][b] = peak
                }
            }
            if b % 40 == 39 || b == bins - 1 { update(peaks, b + 1) }
        }
    }
}
