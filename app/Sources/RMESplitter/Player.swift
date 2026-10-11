import AVFoundation
import Synchronization
import os
import SplitterCore

/// One run of playback from a start frame: a reader thread fills a ring buffer
/// with decoded multichannel audio and the render callback mixes it to stereo,
/// so mute/solo changes are heard immediately.
final class PlaybackSession: @unchecked Sendable {
    let recording: Recording
    let channels: Int
    let capacity: Int
    let ring: UnsafeMutablePointer<Float>
    /// Left/right gain per source channel: [l0, r0, l1, r1, ...].
    let gains: UnsafeMutablePointer<Float>
    let startFrame: Int64
    let endFrame: Atomic<Int64>
    let writeIndex = Atomic<Int>(0)
    let readIndex = Atomic<Int>(0)
    let stopped = Atomic<Bool>(false)
    let endOfStream = Atomic<Bool>(false)
    let finished = Atomic<Bool>(false)

    init(recording: Recording, start: Int64, end: Int64, gains initial: [Float]) {
        self.recording = recording
        channels = recording.channels
        capacity = max(8192, recording.sampleRate / 2)
        ring = .allocate(capacity: capacity * channels)
        gains = .allocate(capacity: channels * 2)
        startFrame = start
        endFrame = Atomic(end)
        setGains(initial)
    }

    deinit {
        ring.deallocate()
        gains.deallocate()
    }

    func setGains(_ values: [Float]) {
        for i in 0..<channels * 2 { gains[i] = i < values.count ? values[i] : 0 }
    }

    var currentFrame: Int64 { startFrame + Int64(readIndex.load(ordering: .relaxed)) }

    func startReader() {
        Thread.detachNewThread { [self] in
            let chunk = 4096
            let raw = UnsafeMutableRawPointer.allocate(byteCount: chunk * recording.frameBytes, alignment: 16)
            let decoded = UnsafeMutablePointer<Float>.allocate(capacity: chunk * channels)
            defer { raw.deallocate(); decoded.deallocate() }
            var position = startFrame

            while !stopped.load(ordering: .relaxed) {
                let end = endFrame.load(ordering: .relaxed)
                if position >= end { break }
                let w = writeIndex.load(ordering: .relaxed)
                let r = readIndex.load(ordering: .acquiring)
                if capacity - (w - r) < chunk {
                    Thread.sleep(forTimeInterval: 0.004)
                    continue
                }
                let want = Int(min(Int64(chunk), end - position))
                let got = (try? recording.read(frame: position, count: want, into: raw)) ?? 0
                if got == 0 { break }
                PCM.decode(raw, format: recording.format, count: got * channels, into: decoded)
                let at = w % capacity
                let first = min(got, capacity - at)
                (ring + at * channels).update(from: decoded, count: first * channels)
                if got > first { ring.update(from: decoded + first * channels, count: (got - first) * channels) }
                writeIndex.store(w + got, ordering: .releasing)
                position += Int64(got)
            }
            endOfStream.store(true, ordering: .releasing)
        }
    }

    /// Called on the audio render thread.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(frames, w - r)
        for i in 0..<n {
            let base = ((r + i) % capacity) * channels
            var l: Float = 0
            var rr: Float = 0
            for c in 0..<channels {
                let v = ring[base + c]
                l += v * gains[c * 2]
                rr += v * gains[c * 2 + 1]
            }
            left[i] = max(-1, min(1, l))
            right[i] = max(-1, min(1, rr))
        }
        readIndex.store(r + n, ordering: .releasing)
        if n < frames, endOfStream.load(ordering: .acquiring), writeIndex.load(ordering: .acquiring) == r + n {
            finished.store(true, ordering: .relaxed)
        }
    }
}

final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Int64 = 0
    @Published var volume: Float = 0.7 { didSet { pushGains() } }
    @Published var error: String?

    private var recording: Recording?
    private var range: Range<Int64> = 0..<0
    private var tracks: [Track] = []
    private var engine: AVAudioEngine?
    private var session: PlaybackSession?
    private let active = OSAllocatedUnfairLock<PlaybackSession?>(initialState: nil)
    private var timer: Timer?

    func load(_ recording: Recording?, range: Range<Int64>, tracks: [Track]) {
        pause()
        engine?.stop()
        engine = nil
        self.recording = recording
        self.range = range
        self.tracks = tracks
        position = range.lowerBound
    }

    func setTracks(_ tracks: [Track]) {
        self.tracks = tracks
        pushGains()
    }

    func setRange(_ range: Range<Int64>) {
        self.range = range
        session?.endFrame.store(range.upperBound, ordering: .relaxed)
        if position < range.lowerBound || position > range.upperBound {
            seek(to: range.lowerBound)
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let recording, !range.isEmpty, !isPlaying else { return }
        if position < range.lowerBound || position >= range.upperBound - 1 { position = range.lowerBound }
        do {
            let engine = try self.engine ?? makeEngine(for: recording)
            self.engine = engine
            startSession(recording)
            if !engine.isRunning { try engine.start() }
        } catch {
            stopSession()
            self.error = "Couldn't start audio playback: \(error.localizedDescription)"
            return
        }
        isPlaying = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        guard isPlaying else { return }
        if let session { position = min(session.currentFrame, range.upperBound) }
        stopSession()
        engine?.pause()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func seek(to frame: Int64) {
        guard let recording, !range.isEmpty else { return }
        position = max(range.lowerBound, min(frame, range.upperBound))
        if isPlaying {
            stopSession()
            startSession(recording)
        }
    }

    private func startSession(_ recording: Recording) {
        let s = PlaybackSession(recording: recording, start: position, end: range.upperBound, gains: gains())
        session = s
        active.withLock { $0 = s }
        s.startReader()
    }

    private func stopSession() {
        session?.stopped.store(true, ordering: .relaxed)
        session = nil
        active.withLock { $0 = nil }
    }

    private func tick() {
        guard let session else { return }
        if session.finished.load(ordering: .relaxed) {
            pause()
            position = range.lowerBound
        } else {
            position = session.currentFrame
        }
    }

    private func gains() -> [Float] {
        guard let recording else { return [] }
        var g = [Float](repeating: 0, count: recording.channels * 2)
        let anySolo = tracks.contains(where: \.solo)
        for t in tracks where anySolo ? t.solo : !t.mute {
            guard t.channels.allSatisfy({ $0 < recording.channels }) else { continue }
            if t.channels.count == 2 {
                g[t.channels[0] * 2] += volume
                g[t.channels[1] * 2 + 1] += volume
            } else if let c = t.channels.first {
                g[c * 2] += volume
                g[c * 2 + 1] += volume
            }
        }
        return g
    }

    private func pushGains() { session?.setGains(gains()) }

    private func makeEngine(for recording: Recording) throws -> AVAudioEngine {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(recording.sampleRate), channels: 2) else {
            throw WavError.unsupported(recording.parts[0].url, "sample rate not playable")
        }
        let engine = AVAudioEngine()
        let active = self.active
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 1, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            l.update(repeating: 0, count: frames)
            r.update(repeating: 0, count: frames)
            // Never block the render thread: skip a cycle if the session is being swapped.
            if let session = active.withLockIfAvailable({ $0 }) ?? nil {
                session.render(left: l, right: r, frames: frames)
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        return engine
    }
}
