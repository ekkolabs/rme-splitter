import XCTest
@testable import SplitterCore

final class SplitterCoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rme-splitter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Deterministic 24-bit sample for a frame/channel, so any output byte can be checked.
    func sample(_ frame: Int, _ channel: Int) -> Int32 {
        Int32((frame * 37 + channel * 100_003) % 8_000_000) - 4_000_000
    }

    func writeSource(_ name: String, channels: Int, frames: Range<Int>, in folder: URL? = nil) throws {
        let w = try WavWriter(url: (folder ?? dir).appendingPathComponent(name), format: .int24, channels: channels, sampleRate: 48000)
        var bytes = [UInt8]()
        for f in frames {
            for c in 0..<channels {
                let v = sample(f, c)
                bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
            }
        }
        try w.write(bytes, count: bytes.count)
        try w.finish()
    }

    func payload(_ url: URL) throws -> (info: WavInfo, data: [UInt8]) {
        let info = try WavInfo.read(url)
        let all = try Data(contentsOf: url)
        let start = Int(info.dataOffset)
        return (info, Array(all[start..<start + Int(info.frameCount) * info.frameBytes]))
    }

    func int24(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(b[i * 3]) | Int32(b[i * 3 + 1]) << 8 | Int32(Int8(bitPattern: b[i * 3 + 2])) << 16
    }

    func testMultipartScanAndBitExactExport() throws {
        // Three parts of one take, plus an unrelated take alongside.
        try writeSource("UFX04_00.WAV", channels: 6, frames: 0..<1000)
        try writeSource("UFX04_01.WAV", channels: 6, frames: 1000..<2000)
        try writeSource("UFX04_02.WAV", channels: 6, frames: 2000..<2501)
        try writeSource("UFX05_00.WAV", channels: 4, frames: 0..<300)
        try Data().write(to: dir.appendingPathComponent("UFX06_00.WAV"))

        let scan = RecordingScanner.scan([dir])
        XCTAssertEqual(scan.recordings.map(\.name), ["UFX04", "UFX05"])
        XCTAssertEqual(scan.skipped.count, 1)
        let rec = scan.recordings[0]
        XCTAssertEqual(rec.parts.count, 3)
        XCTAssertEqual(rec.channels, 6)
        XCTAssertEqual(rec.frameCount, 2501)
        XCTAssertEqual(rec.format, .int24)

        let template = Template(name: "t", tracks: [
            TemplateTrack(channels: [2, 3], name: "01_pair"),
            TemplateTrack(channels: [5], name: "02_mono"),
            TemplateTrack(channels: [8, 9], name: "03_missing"),
        ])
        let applied = Layout.apply(template, channelCount: rec.channels)
        XCTAssertEqual(applied.dropped, 1)
        XCTAssertEqual(applied.tracks.map(\.channels), [[2, 3], [5], [0], [1], [4]])
        XCTAssertEqual(applied.tracks.map(\.export), [true, true, false, false, false])

        // Trim crosses both part boundaries.
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let range: Range<Int64> = 900..<2100
        let outputs = Exporter.plan(tracks: applied.tracks, splitStereo: false, directory: out)
        XCTAssertEqual(outputs.map(\.url.lastPathComponent), ["01_pair.wav", "02_mono.wav"])
        try Exporter.run(recording: rec, range: range, outputs: outputs)

        let pair = try payload(outputs[0].url)
        XCTAssertEqual(pair.info.channels, 2)
        XCTAssertEqual(pair.info.frameCount, 1200)
        XCTAssertEqual(pair.info.sampleRate, 48000)
        let mono = try payload(outputs[1].url)
        XCTAssertEqual(mono.info.channels, 1)
        XCTAssertEqual(mono.info.frameCount, 1200)
        for i in 0..<1200 {
            XCTAssertEqual(int24(pair.data, i * 2), sample(900 + i, 2))
            XCTAssertEqual(int24(pair.data, i * 2 + 1), sample(900 + i, 3))
            XCTAssertEqual(int24(mono.data, i), sample(900 + i, 5))
        }

        // Stereo pair as two mono files.
        let split = Exporter.plan(tracks: applied.tracks, splitStereo: true, directory: out)
        XCTAssertEqual(split.map(\.url.lastPathComponent), ["01_pair_L.wav", "01_pair_R.wav", "02_mono.wav"])
        try Exporter.run(recording: rec, range: 0..<rec.frameCount, outputs: split)
        let right = try payload(split[1].url)
        XCTAssertEqual(right.info.frameCount, 2501)
        for i in stride(from: 0, to: 2501, by: 7) { XCTAssertEqual(int24(right.data, i), sample(i, 3)) }
    }

    func testBitDepthConversion() throws {
        try writeSource("take.wav", channels: 3, frames: 0..<500)
        let rec = RecordingScanner.scan([dir.appendingPathComponent("take.wav")]).recordings[0]
        XCTAssertEqual(rec.name, "take")

        let f32 = [ExportOutput(url: dir.appendingPathComponent("f.wav"), channels: [1])]
        try Exporter.run(recording: rec, range: 0..<500, outputs: f32, format: .float32)
        let f = try payload(f32[0].url)
        XCTAssertEqual(f.info.format, .float32)
        f.data.withUnsafeBytes { p in
            for i in 0..<500 {
                XCTAssertEqual(p.loadUnaligned(fromByteOffset: i * 4, as: Float.self), Float(sample(i, 1)) / 8_388_608)
            }
        }

        let i16 = [ExportOutput(url: dir.appendingPathComponent("s.wav"), channels: [0, 2])]
        try Exporter.run(recording: rec, range: 0..<500, outputs: i16, format: .int16)
        let s = try payload(i16[0].url)
        XCTAssertEqual(s.info.format, .int16)
        s.data.withUnsafeBytes { p in
            for i in 0..<500 {
                let got = Int(p.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                XCTAssertLessThanOrEqual(abs(got - Int(sample(i, 2)) / 256), 2)
            }
        }
    }

    func testGroupingOfNonRecorderNames() throws {
        // "song_1"/"song_2" are separate takes unless the first hit a size limit.
        try writeSource("song_1.wav", channels: 2, frames: 0..<100)
        try writeSource("song_2.wav", channels: 2, frames: 0..<100)
        XCTAssertEqual(RecordingScanner.scan([dir]).recordings.map(\.name), ["song_1", "song_2"])
        let joined = RecordingScanner.scan([dir], splitSizeThreshold: 100)
        XCTAssertEqual(joined.recordings.map(\.name), ["song"])
        XCTAssertEqual(joined.recordings[0].frameCount, 200)
    }

    func testDroppedPartFindsSiblingsAndSourceIsProtected() throws {
        try writeSource("UFX09_00.WAV", channels: 2, frames: 0..<100)
        try writeSource("UFX09_01.WAV", channels: 2, frames: 100..<150)
        let rec = RecordingScanner.scan([dir.appendingPathComponent("UFX09_01.WAV")]).recordings
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec[0].frameCount, 150)

        let clash = Exporter.plan(tracks: [Track(channels: [0, 1], name: "ufx09_00")], splitStereo: false, directory: dir)
        XCTAssertThrowsError(try Exporter.run(recording: rec[0], range: 0..<150, outputs: clash))
        XCTAssertEqual(try WavInfo.read(dir.appendingPathComponent("UFX09_00.WAV")).frameCount, 100)
    }

    func testConfRoundTripAndBundledTemplates() throws {
        let text = """
        # rme-split channel layout config
        # Snapshot: MXGPU PSP (20 channels)

        2-3     01_out_vox
        10      05 bass take
        """
        let parsed = ConfFormat.parse(text)
        XCTAssertEqual(parsed.tracks.map(\.channels), [[2, 3], [10]])
        XCTAssertEqual(parsed.tracks.map(\.name), ["01_out_vox", "05 bass take"])
        XCTAssertEqual(parsed.notes, "Snapshot: MXGPU PSP (20 channels)")

        let again = ConfFormat.parse(ConfFormat.serialize(Template(name: "x", notes: parsed.notes, tracks: parsed.tracks)))
        XCTAssertEqual(again.tracks.map(\.channels), parsed.tracks.map(\.channels))
        XCTAssertEqual(again.tracks.map(\.name), parsed.tracks.map(\.name))
        XCTAssertEqual(again.notes, parsed.notes)

        let seeds = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Templates").standardizedFileURL
        let counts = try ["default": 13, "ufx": 14, "recs1": 13, "mouros": 9, "split2": 12].map { name, expected in
            let t = ConfFormat.parse(try String(contentsOf: seeds.appendingPathComponent("\(name).conf"), encoding: .utf8))
            return t.tracks.count == expected
        }
        XCTAssertFalse(counts.contains(false))
    }

    func testChannelSpecAndTimecode() {
        XCTAssertEqual(ChannelSpec.parse("3-4"), [2, 3])
        XCTAssertEqual(ChannelSpec.parse(" 11 "), [10])
        XCTAssertNil(ChannelSpec.parse("0"))
        XCTAssertNil(ChannelSpec.parse("1-2-3"))
        XCTAssertEqual(ChannelSpec.format([2, 3]), "3–4")
        XCTAssertEqual(Timecode.format(frames: 48000 * 3723 + 24000, rate: 48000), "1:02:03.500")
        XCTAssertEqual(Timecode.parse("1:02:03.5", rate: 48000), 48000 * 3723 + 24000)
        XCTAssertEqual(Timecode.parse("90", rate: 48000), 48000 * 90)
        XCTAssertNil(Timecode.parse("abc", rate: 48000))
    }

    /// The app must produce the same audio as the original `cli/rme-split` script.
    func testMatchesCLIOutput() throws {
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../cli").standardizedFileURL
        let ffmpeg = cli.appendingPathComponent("bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("cli/bin/ffmpeg not present") }

        func run(_ tool: URL, _ args: [String]) throws {
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(tool.lastPathComponent) failed")
        }

        // 20 channels, split by the recorder into three parts.
        let src = dir.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let exprs = (0..<20).map { "0.5*sin(2*PI*\(110 + 37 * $0)*t)*(0.3+0.7*abs(sin(t*\($0 + 1)/7)))" }.joined(separator: "|")
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "aevalsrc=\(exprs):s=48000:d=5", "-c:a", "pcm_s24le",
                         "-f", "segment", "-segment_time", "2", src.appendingPathComponent("UFX07_%02d.WAV").path])

        let expected = dir.appendingPathComponent("cli-out")
        try run(cli.appendingPathComponent("rme-split"), ["split", src.appendingPathComponent("UFX07_00.WAV").path, expected.path])

        let rec = try XCTUnwrap(RecordingScanner.scan([src]).recordings.first)
        XCTAssertEqual(rec.parts.count, 3)
        let conf = try String(contentsOf: cli.appendingPathComponent("rme-split.conf"), encoding: .utf8)
        let tracks = Layout.apply(Template(name: "default", tracks: ConfFormat.parse(conf).tracks), channelCount: rec.channels).tracks
        let actual = dir.appendingPathComponent("app-out")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let outputs = Exporter.plan(tracks: tracks, splitStereo: false, directory: actual)
        XCTAssertEqual(outputs.count, 13)
        try Exporter.run(recording: rec, range: 0..<rec.frameCount, outputs: outputs)

        for o in outputs {
            let mine = try payload(o.url)
            let theirs = try payload(expected.appendingPathComponent(o.url.lastPathComponent))
            XCTAssertEqual(mine.info.channels, theirs.info.channels, o.url.lastPathComponent)
            XCTAssertEqual(mine.info.frameCount, rec.frameCount)
            XCTAssertTrue(mine.data == theirs.data, "\(o.url.lastPathComponent) differs from the CLI output")
        }
    }

    func testDatedNameAndFilePrefix() throws {
        try writeSource("UFX03_00.WAV", channels: 2, frames: 0..<10)
        let url = dir.appendingPathComponent("UFX03_00.WAV")
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 21)))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date.addingTimeInterval(600)], ofItemAtPath: url.path)
        let rec = try XCTUnwrap(RecordingScanner.scan([url]).recordings.first)
        XCTAssertEqual(rec.created, date)
        XCTAssertEqual(rec.datedName, "20250309_-_UFX03")

        let outputs = Exporter.plan(tracks: [Track(channels: [0, 1], name: "01_vox")], splitStereo: true,
                                    directory: dir, prefix: rec.datedName + "_")
        XCTAssertEqual(outputs.map(\.url.lastPathComponent), ["20250309_-_UFX03_01_vox_L.wav", "20250309_-_UFX03_01_vox_R.wav"])
    }
}
