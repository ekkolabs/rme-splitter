import Foundation

public struct ExportOutput: Equatable, Sendable {
    public var url: URL
    public var channels: [Int]
}

public enum ExportError: LocalizedError {
    case nothingToExport
    case wouldOverwriteSource(URL)
    case badChannel(String)
    case truncatedSource

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: return "No tracks are selected for export."
        case .wouldOverwriteSource(let u): return "\(u.lastPathComponent) would overwrite the source recording. Choose another folder or track name."
        case .badChannel(let name): return "Track “\(name)” uses a channel this recording doesn't have."
        case .truncatedSource: return "The source recording ended unexpectedly."
        }
    }
}

public enum Exporter {
    public static func sanitize(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        s = String(s.map { "/:\\\0".contains($0) ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    /// Output files for the tracks marked for export. A stereo track becomes
    /// one stereo file, or `_L` / `_R` mono files when `splitStereo` is set.
    /// `prefix` goes in front of every file name.
    public static func plan(tracks: [Track], splitStereo: Bool, directory: URL, prefix: String = "") -> [ExportOutput] {
        var outputs: [ExportOutput] = []
        var taken = Set<String>()

        func add(_ base: String, _ channels: [Int]) {
            var name = base
            var n = 2
            while !taken.insert(name.lowercased()).inserted {
                name = "\(base)_\(n)"
                n += 1
            }
            outputs.append(ExportOutput(url: directory.appendingPathComponent(name + ".wav"), channels: channels))
        }

        for t in tracks where t.export && !t.channels.isEmpty {
            var base = sanitize(t.name)
            if base.isEmpty { base = Layout.channelName(t.channels[0]) }
            base = prefix + base
            if t.isStereo && splitStereo {
                add(base + "_L", [t.channels[0]])
                add(base + "_R", [t.channels[1]])
            } else {
                add(base, t.channels)
            }
        }
        return outputs
    }

    /// Single pass over `range`, writing every output at once. `format: nil`
    /// keeps the source sample format, which copies samples bit for bit.
    public static func run(recording rec: Recording, range: Range<Int64>, outputs: [ExportOutput],
                           format: SampleFormat? = nil, isCancelled: () -> Bool = { false },
                           progress: (Double) -> Void = { _ in }) throws {
        guard !outputs.isEmpty, !range.isEmpty else { throw ExportError.nothingToExport }
        let src = rec.format
        let dst = format ?? src
        let convert = dst != src
        let nch = rec.channels
        let fb = rec.frameBytes

        let sources = Set(rec.parts.map { $0.url.standardizedFileURL.path.lowercased() })
        for o in outputs {
            guard o.channels.allSatisfy({ $0 >= 0 && $0 < nch }) else {
                throw ExportError.badChannel(o.url.deletingPathExtension().lastPathComponent)
            }
            if sources.contains(o.url.standardizedFileURL.path.lowercased()) { throw ExportError.wouldOverwriteSource(o.url) }
        }

        let chunk = 16384
        let maxOut = outputs.map(\.channels.count).max() ?? 1
        let raw = UnsafeMutableRawPointer.allocate(byteCount: chunk * fb, alignment: 16)
        let out = UnsafeMutableRawPointer.allocate(byteCount: chunk * maxOut * dst.bytes, alignment: 16)
        let fin = UnsafeMutablePointer<Float>.allocate(capacity: convert ? chunk * nch : 1)
        let fout = UnsafeMutablePointer<Float>.allocate(capacity: convert ? chunk * maxOut : 1)
        defer { raw.deallocate(); out.deallocate(); fin.deallocate(); fout.deallocate() }

        var writers: [WavWriter] = []
        do {
            for o in outputs {
                writers.append(try WavWriter(url: o.url, format: dst, channels: o.channels.count, sampleRate: rec.sampleRate))
            }
            var rng: UInt32 = 0x2545_F491
            var pos = range.lowerBound
            let total = Double(range.upperBound - range.lowerBound)
            let bps = src.bytes

            while pos < range.upperBound {
                if isCancelled() { throw CancellationError() }
                let want = Int(min(Int64(chunk), range.upperBound - pos))
                let got = try rec.read(frame: pos, count: want, into: raw)
                guard got == want else { throw ExportError.truncatedSource }
                if convert { PCM.decode(raw, format: src, count: got * nch, into: fin) }

                for (writer, o) in zip(writers, outputs) {
                    let oc = o.channels.count
                    if convert {
                        for (k, c) in o.channels.enumerated() {
                            for i in 0..<got { fout[i * oc + k] = fin[i * nch + c] }
                        }
                        PCM.encode(fout, count: got * oc, format: dst, into: out, rng: &rng)
                    } else {
                        let stride = oc * bps
                        for (k, c) in o.channels.enumerated() {
                            var s = UnsafeRawPointer(raw) + c * bps
                            var d = out + k * bps
                            switch bps {
                            case 2:
                                for _ in 0..<got {
                                    d.storeBytes(of: s.loadUnaligned(as: UInt16.self), as: UInt16.self)
                                    s += fb; d += stride
                                }
                            case 3:
                                for _ in 0..<got {
                                    d.storeBytes(of: s.loadUnaligned(as: UInt16.self), as: UInt16.self)
                                    d.storeBytes(of: s.load(fromByteOffset: 2, as: UInt8.self), toByteOffset: 2, as: UInt8.self)
                                    s += fb; d += stride
                                }
                            default:
                                for _ in 0..<got {
                                    d.storeBytes(of: s.loadUnaligned(as: UInt32.self), as: UInt32.self)
                                    s += fb; d += stride
                                }
                            }
                        }
                    }
                    try writer.write(out, count: got * oc * dst.bytes)
                }
                pos += Int64(got)
                progress(Double(pos - range.lowerBound) / total)
            }
            for w in writers { try w.finish() }
        } catch {
            writers.forEach { $0.abort() }
            throw error
        }
    }
}
