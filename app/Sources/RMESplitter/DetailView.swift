import SwiftUI
import SplitterCore

struct DetailView: View {
    @ObservedObject var doc: RecordingDoc
    @ObservedObject var model: AppModel
    @EnvironmentObject private var store: TemplateStore
    @State private var namingTemplate = false
    @State private var newTemplateName = ""
    /// Where the track waveforms sit, so the overview can line up with them.
    @State private var waveColumn: CGRect = .zero

    private var recording: Recording { doc.recording }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    PlayControls(player: model.player, rate: recording.sampleRate)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .frame(width: max(waveColumn.minX, 230), alignment: .leading)
                OverviewView(doc: doc, player: model.player)
                    .frame(width: waveColumn.width > 0 ? waveColumn.width : nil)
                Spacer(minLength: 0)
            }
            TransportBar(doc: doc, player: model.player)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            templateBar
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($doc.tracks) { $track in
                        let index = doc.tracks.firstIndex { $0.id == track.id } ?? 0
                        TrackRow(track: $track, peaks: doc.peaks(for: track), canLink: doc.canLink(track.id),
                                 player: model.player, total: CGFloat(max(recording.frameCount, 1)),
                                 link: { doc.linkWithNext(track.id) }, split: { doc.split(track.id) },
                                 audition: { frame, begin in audition(track.id, at: frame, begin: begin) })
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            exportBar
        }
        .coordinateSpace(name: "detail")
        .onPreferenceChange(WaveColumnKey.self) { waveColumn = $0 }
        .onChange(of: doc.tracks) { _, tracks in model.player.setTracks(tracks) }
        .onChange(of: doc.inFrame) { _, _ in model.player.setRange(doc.range) }
        .onChange(of: doc.outFrame) { _, _ in model.player.setRange(doc.range) }
    }

    /// Clicking or scrubbing a track's waveform solos it and plays from there.
    private func audition(_ id: Track.ID, at frame: Int64, begin: Bool) {
        if begin {
            doc.soloOnly(id)
            model.player.setTracks(doc.tracks)
        }
        model.player.seek(to: frame)
        if begin, !model.player.isPlaying { model.player.play() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(recording.datedName, text: $doc.exportName)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .help("Name for this recording's export")
                Picker("Use as", selection: $model.nameUse) {
                    ForEach(NameUse.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Text(namePreview).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if doc.analysing {
                    ProgressView().controlSize(.small)
                    Text("Drawing waveforms…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(summary).foregroundStyle(.secondary).lineLimit(1)
            if let notice = doc.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Example of where the first exported file will land.
    private var namePreview: String {
        guard let first = doc.tracks.first(where: \.export) else { return "" }
        var name = Exporter.sanitize(doc.exportName)
        if name.isEmpty { name = recording.datedName }
        let file = (model.nameUse == .prefix || model.nameUse == .both ? name + "_" : "") + Exporter.sanitize(first.name) + ".wav"
        return "→ " + (model.nameUse == .folder || model.nameUse == .both ? name + "/" + file : file)
    }

    private var summary: String {
        var bits = [
            "\(recording.channels) channels",
            String(format: "%g kHz", Double(recording.sampleRate) / 1000),
            recording.format.label,
            Timecode.short(seconds: recording.duration),
        ]
        if recording.parts.count > 1 { bits.append("\(recording.parts.count) parts") }
        bits.append(ByteCountFormatter.string(fromByteCount: Int64(recording.totalBytes), countStyle: .file))
        if let created = recording.created {
            bits.insert("Recorded " + created.formatted(date: .abbreviated, time: .shortened), at: 0)
        }
        return bits.joined(separator: " · ")
    }

    private var templateBar: some View {
        HStack(spacing: 10) {
            Text("Template").foregroundStyle(.secondary)
            Menu(store.template(doc.templateID)?.name ?? "None") {
                ForEach(store.templates) { template in
                    Button(template.channelsNeeded > recording.channels
                           ? "\(template.name)  (needs \(template.channelsNeeded) channels)" : template.name) {
                        model.apply(template, to: doc)
                    }
                }
                if !store.templates.isEmpty { Divider() }
                Button("Reset to Mono Channels") { doc.resetToMono() }
            }
            .fixedSize()
            if let template = store.template(doc.templateID), model.layoutDiffersFromTemplate(doc) {
                Button("Update “\(template.name)”") { model.updateTemplate(from: doc) }
            }
            Button("Save as Template…") {
                newTemplateName = ""
                namingTemplate = true
            }
            Spacer()
            Button("Manage Templates…") { model.showingTemplates = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .alert("Save as Template", isPresented: $namingTemplate) {
            TextField("Name", text: $newTemplateName)
            Button("Save") { model.saveTemplate(named: newTemplateName, from: doc) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the names and channel pairing of the tracks ticked for export.")
        }
    }

    private var fileCount: Int {
        doc.tracks.filter(\.export).reduce(0) { $0 + ($1.isStereo && model.splitStereo ? 2 : 1) }
    }

    private var exportBar: some View {
        HStack(spacing: 14) {
            Picker("Stereo tracks", selection: $model.splitStereo) {
                Text("Stereo files").tag(false)
                Text("Separate L / R mono files").tag(true)
            }
            .fixedSize()
            Picker("Bit depth", selection: $model.bitDepth) {
                Text("Same as source (\(recording.format.label))").tag(BitDepthChoice.source)
                Text("16-bit").tag(BitDepthChoice.int16)
                Text("24-bit").tag(BitDepthChoice.int24)
                Text("32-bit float").tag(BitDepthChoice.float32)
            }
            .fixedSize()
            Spacer()
            switch model.exportPhase {
            case .running(let fraction):
                ProgressView(value: fraction).frame(width: 180)
                Text("\(Int(fraction * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                Button("Cancel") { model.cancelExport() }
            case .done(let folder, let files):
                Label("\(files) files exported", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                Button("Show in Finder") { NSWorkspace.shared.open(folder) }
            case .idle:
                EmptyView()
            }
            if !model.isExporting {
                Button(fileCount == 1 ? "Export 1 File…" : "Export \(fileCount) Files…") { model.export(doc) }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct WaveColumnKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

struct TrackRow: View {
    @Binding var track: Track
    let peaks: [Float]
    let canLink: Bool
    let player: Player
    let total: CGFloat
    let link: () -> Void
    let split: () -> Void
    /// Frame under the pointer, and whether this is the start of a click or scrub.
    let audition: (Int64, Bool) -> Void
    @State private var scrubbing = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Export", isOn: $track.export)
                .labelsHidden()
                .help("Include in export")
            Text(ChannelSpec.format(track.channels))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Button(action: track.isStereo ? split : link) {
                Text(track.isStereo ? "Stereo" : "Mono").frame(width: 44)
            }
            .controlSize(.small)
            .disabled(!track.isStereo && !canLink)
            .help(track.isStereo ? "Split into two mono tracks" : "Pair with the track below as stereo")
            TextField("Track name", text: $track.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .opacity(track.export ? 1 : 0.6)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PeaksView(peaks: peaks, color: track.export ? .accentColor : .secondary).equatable()
                    PlayheadView(player: player, total: total, width: geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                            audition(Int64(fraction * total), !scrubbing)
                            scrubbing = true
                        }
                        .onEnded { _ in scrubbing = false }
                )
                .preference(key: WaveColumnKey.self, value: geo.frame(in: .named("detail")))
            }
            .frame(height: 28)
            .help("Click or drag to hear this track on its own")
            ToggleChip(label: "M", help: "Mute", color: .orange, isOn: $track.mute)
            ToggleChip(label: "S", help: "Solo", color: .yellow, isOn: $track.solo)
        }
    }
}

struct ToggleChip: View {
    let label: String
    let help: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 20)
                .foregroundStyle(isOn ? Color.black : Color.secondary)
                .background(isOn ? color : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Peak envelope drawn as one bar per point.
struct PeaksView: View, Equatable {
    let peaks: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let n = peaks.count
            let width = Int(size.width)
            guard n > 0, width > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            for x in 0..<width {
                let a = x * n / width
                let b = min(n, max(a + 1, (x + 1) * n / width))
                var peak: Float = 0
                for i in a..<b { peak = max(peak, peaks[i]) }
                // Compress the range so quiet channels are still visible.
                let h = max(0.5, CGFloat(pow(min(peak, 1), 0.6)) * mid)
                path.addRect(CGRect(x: CGFloat(x), y: mid - h, width: 1, height: h * 2))
            }
            context.fill(path, with: .color(color))
        }
    }
}

/// Whole-recording waveform with draggable in/out handles. Click or drag
/// anywhere else to move the playhead.
struct OverviewView: View {
    @ObservedObject var doc: RecordingDoc
    let player: Player
    @State private var dragging: Target?

    private enum Target { case inPoint, outPoint, playhead }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let total = CGFloat(max(doc.recording.frameCount, 1))
            let inX = CGFloat(doc.inFrame) / total * width
            let outX = CGFloat(doc.outFrame) / total * width

            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.06)
                PeaksView(peaks: doc.mixPeaks, color: .accentColor).equatable()
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    .frame(width: max(0, inX))
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    .frame(width: max(0, width - outX))
                    .offset(x: outX)
                TrimHandle(leading: true).offset(x: inX)
                TrimHandle(leading: false).offset(x: outX - TrimHandle.width)
                PlayheadView(player: player, total: total, width: width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x
                        if dragging == nil {
                            let start = value.startLocation.x
                            if abs(start - inX) <= 8 { dragging = .inPoint }
                            else if abs(start - outX) <= 8 { dragging = .outPoint }
                            else { dragging = .playhead }
                        }
                        let frame = Int64(max(0, min(1, x / width)) * total)
                        switch dragging {
                        case .inPoint: doc.setIn(frame)
                        case .outPoint: doc.setOut(frame)
                        default: player.seek(to: frame)
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Waveform overview with trim handles")
    }
}

struct TrimHandle: View {
    static let width: CGFloat = 9
    let leading: Bool

    var body: some View {
        HStack(spacing: 0) {
            if !leading { Spacer(minLength: 0) }
            Rectangle().fill(Color.orange).frame(width: 2)
            if leading { Spacer(minLength: 0) }
        }
        .frame(width: Self.width)
        .overlay(alignment: leading ? .topLeading : .topTrailing) {
            UnevenRoundedRectangle(cornerRadii: leading
                ? .init(bottomTrailing: 4, topTrailing: 4) : .init(topLeading: 4, bottomLeading: 4))
                .fill(Color.orange)
                .frame(width: Self.width, height: 20)
        }
        .allowsHitTesting(false)
    }
}

struct PlayheadView: View {
    @ObservedObject var player: Player
    let total: CGFloat
    let width: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 1)
            .offset(x: CGFloat(player.position) / total * width)
            .allowsHitTesting(false)
    }
}

struct TransportBar: View {
    @ObservedObject var doc: RecordingDoc
    let player: Player

    private var rate: Int { doc.recording.sampleRate }

    var body: some View {
        HStack(spacing: 12) {
            Text("In").foregroundStyle(.secondary)
            TimeField(frame: doc.inFrame, rate: rate) { doc.setIn($0) }
            Button { doc.setIn(player.position) } label: { Image(systemName: "arrow.down.to.line") }
                .help("Set the start to the playhead (I)")
            Text("Out").foregroundStyle(.secondary).padding(.leading, 6)
            TimeField(frame: doc.outFrame, rate: rate) { doc.setOut($0) }
            Button { doc.setOut(player.position) } label: { Image(systemName: "arrow.down.to.line") }
                .help("Set the end to the playhead (O)")
            Text("Length \(Timecode.format(frames: doc.outFrame - doc.inFrame, rate: rate))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 6)
            if doc.isTrimmed {
                Button("Reset Trim") { doc.resetTrim() }
            }
            Spacer()
            VolumeSlider(player: player)
        }
    }
}

struct PlayControls: View {
    @ObservedObject var player: Player
    let rate: Int

    var body: some View {
        Button { player.toggle() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
        }
        .controlSize(.large)
        .help("Play or pause (Space)")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        Text(Timecode.format(frames: player.position, rate: rate))
            .font(.system(.title3, design: .monospaced))
            .frame(width: 132, alignment: .leading)
    }
}

struct VolumeSlider: View {
    @ObservedObject var player: Player

    var body: some View {
        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
        Slider(value: $player.volume, in: 0...1)
            .frame(width: 110)
            .accessibilityLabel("Preview volume")
    }
}

struct TimeField: View {
    let frame: Int64
    let rate: Int
    let commit: (Int64) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var formatted: String { Timecode.format(frames: frame, rate: rate) }

    var body: some View {
        TextField("0:00:00.000", text: $text)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 108)
            .focused($focused)
            .onAppear { text = formatted }
            .onChange(of: frame) { _, _ in text = formatted }
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        if text != formatted, let parsed = Timecode.parse(text, rate: rate) { commit(parsed) }
        text = formatted
    }
}
