import AppKit
import Synchronization
import SplitterCore

final class CancelFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// A recording plus everything the user has set up for it.
final class RecordingDoc: ObservableObject, Identifiable {
    let recording: Recording
    var id: UUID { recording.id }

    @Published var tracks: [Track]
    /// Name given to the export folder and/or file prefix. Editable.
    @Published var exportName: String
    @Published var inFrame: Int64 = 0
    @Published var outFrame: Int64
    @Published var templateID: UUID?
    @Published var notice: String?
    @Published private(set) var peaks: [[Float]] = []
    @Published private(set) var mixPeaks: [Float] = []
    @Published private(set) var analysing = false

    private var overviewCancel: CancelFlag?

    init(recording: Recording) {
        self.recording = recording
        tracks = Layout.mono(channelCount: recording.channels)
        exportName = recording.datedName
        outFrame = recording.frameCount
    }

    deinit { overviewCancel?.cancel() }

    var range: Range<Int64> { inFrame..<max(inFrame, outFrame) }
    var minimumLength: Int64 { min(recording.frameCount, Int64(max(1, recording.sampleRate / 10))) }
    var isTrimmed: Bool { inFrame > 0 || outFrame < recording.frameCount }

    func setIn(_ frame: Int64) { inFrame = max(0, min(frame, outFrame - minimumLength)) }
    func setOut(_ frame: Int64) { outFrame = min(recording.frameCount, max(frame, inFrame + minimumLength)) }
    func resetTrim() {
        inFrame = 0
        outFrame = recording.frameCount
    }

    func apply(_ template: Template) {
        let result = Layout.apply(template, channelCount: recording.channels)
        tracks = result.tracks
        templateID = template.id
        notice = result.dropped > 0
            ? "“\(template.name)” expects \(template.channelsNeeded) channels. \(result.dropped) of its tracks don't fit this \(recording.channels)-channel recording and were left out."
            : nil
    }

    func resetToMono() {
        tracks = Layout.mono(channelCount: recording.channels)
        templateID = nil
        notice = nil
    }

    func peaks(for track: Track) -> [Float] {
        let sets = track.channels.compactMap { $0 < peaks.count ? peaks[$0] : nil }
        guard let first = sets.first else { return [] }
        return sets.count == 1 ? first : zip(first, sets[1]).map(max)
    }

    func soloOnly(_ id: Track.ID) {
        for i in tracks.indices { tracks[i].solo = tracks[i].id == id }
    }

    func canLink(_ id: Track.ID) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }), i + 1 < tracks.count else { return false }
        return !tracks[i].isStereo && !tracks[i + 1].isStereo
    }

    /// Merges a mono track with the one below it into a stereo pair.
    func linkWithNext(_ id: Track.ID) {
        guard canLink(id), let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let next = tracks.remove(at: i + 1)
        tracks[i].channels += next.channels
        tracks[i].export = tracks[i].export || next.export
        for suffix in ["_L", "_l", " L", ".L"] where tracks[i].name.hasSuffix(suffix) {
            tracks[i].name.removeLast(suffix.count)
            break
        }
    }

    func split(_ id: Track.ID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].isStereo else { return }
        let t = tracks[i]
        var left = t
        left.channels = [t.channels[0]]
        left.name = t.name + "_L"
        var right = Track(channels: [t.channels[1]], name: t.name + "_R", export: t.export)
        right.mute = t.mute
        right.solo = t.solo
        tracks.replaceSubrange(i...i, with: [left, right])
    }

    func startOverview() {
        guard overviewCancel == nil else { return }
        let cancel = CancelFlag()
        overviewCancel = cancel
        analysing = true
        let recording = recording
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Overview.compute(recording, isCancelled: { cancel.isCancelled }) { peaks, _ in
                let mix = peaks.first.map { first in
                    first.indices.map { i in peaks.reduce(Float(0)) { max($0, $1[i]) } }
                } ?? []
                DispatchQueue.main.async {
                    self?.peaks = peaks
                    self?.mixPeaks = mix
                }
            }
            DispatchQueue.main.async { self?.analysing = false }
        }
    }
}

enum ExportPhase: Equatable {
    case idle
    case running(Double)
    case done(folder: URL, files: Int)
}

enum BitDepthChoice: String, CaseIterable, Identifiable {
    case source, int16, int24, float32
    var id: String { rawValue }

    var format: SampleFormat? {
        switch self {
        case .source: return nil
        case .int16: return .int16
        case .int24: return .int24
        case .float32: return .float32
        }
    }
}

/// How the recording's name is used when exporting.
enum NameUse: String, CaseIterable, Identifiable {
    case folder, prefix, both, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: return "Folder"
        case .prefix: return "File prefix"
        case .both: return "Folder and file prefix"
        case .off: return "Not used"
        }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var docs: [RecordingDoc] = []
    @Published var selection: UUID? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published var isScanning = false
    @Published var exportPhase: ExportPhase = .idle
    @Published var showingTemplates = false
    @Published var alertTitle = ""
    @Published var alertMessage: String?
    @Published var splitStereo = UserDefaults.standard.bool(forKey: "splitStereo") {
        didSet { UserDefaults.standard.set(splitStereo, forKey: "splitStereo") }
    }
    @Published var bitDepth = BitDepthChoice(rawValue: UserDefaults.standard.string(forKey: "bitDepth") ?? "") ?? .source {
        didSet { UserDefaults.standard.set(bitDepth.rawValue, forKey: "bitDepth") }
    }

    @Published var nameUse = NameUse(rawValue: UserDefaults.standard.string(forKey: "nameUse") ?? "") ?? .folder {
        didSet { UserDefaults.standard.set(nameUse.rawValue, forKey: "nameUse") }
    }

    let player = Player()
    let templates = TemplateStore()
    private var exportCancel: CancelFlag?

    var current: RecordingDoc? { docs.first { $0.id == selection } }
    var isExporting: Bool { if case .running = exportPhase { return true } else { return false } }

    init() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.wav, .folder]
        panel.message = "Choose a folder of recordings or a WAV file"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// `restoring` is the reopen at launch, which stays quiet if nothing is found.
    func open(_ urls: [URL], restoring: Bool = false) {
        guard !urls.isEmpty, !isExporting, !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RecordingScanner.scan(urls)
            DispatchQueue.main.async { self.finishOpen(result, from: urls, restoring: restoring) }
        }
    }

    /// Reopens whatever was open last time, if it's still there (an SD card may not be).
    func reopenLast() {
        guard docs.isEmpty, !isScanning, let paths = UserDefaults.standard.stringArray(forKey: "lastOpened") else { return }
        let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        open(urls, restoring: true)
    }

    private func finishOpen(_ result: ScanResult, from urls: [URL], restoring: Bool) {
        isScanning = false
        let skipped = result.skipped.prefix(8).map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
        guard !result.recordings.isEmpty else {
            if !restoring {
                alert("No recordings found", skipped.isEmpty ? "There are no WAV files in what you dropped." : skipped)
            }
            return
        }
        UserDefaults.standard.set(urls.map(\.path), forKey: "lastOpened")
        exportPhase = .idle
        docs = result.recordings.map { rec in
            let doc = RecordingDoc(recording: rec)
            // Reuse whichever template was last applied to a recording with this channel count.
            if let saved = UserDefaults.standard.string(forKey: "template.\(rec.channels)"),
               let template = templates.template(UUID(uuidString: saved)) {
                doc.apply(template)
            }
            return doc
        }
        selection = docs.first?.id
        if !result.skipped.isEmpty, !restoring {
            alert("Some files were skipped", skipped + (result.skipped.count > 8 ? "\n…and \(result.skipped.count - 8) more" : ""))
        }
    }

    private func selectionChanged() {
        guard let doc = current else {
            player.load(nil, range: 0..<0, tracks: [])
            return
        }
        player.load(doc.recording, range: doc.range, tracks: doc.tracks)
        doc.startOverview()
    }

    func alert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
    }

    // MARK: Templates

    func apply(_ template: Template, to doc: RecordingDoc) {
        doc.apply(template)
        UserDefaults.standard.set(template.id.uuidString, forKey: "template.\(doc.recording.channels)")
    }

    func saveTemplate(named name: String, from doc: RecordingDoc) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let template = Template(name: templates.uniqueName(trimmed.isEmpty ? "Untitled" : trimmed),
                                tracks: Layout.templateTracks(from: doc.tracks))
        templates.templates.append(template)
        doc.templateID = template.id
        UserDefaults.standard.set(template.id.uuidString, forKey: "template.\(doc.recording.channels)")
    }

    func updateTemplate(from doc: RecordingDoc) {
        guard let i = templates.templates.firstIndex(where: { $0.id == doc.templateID }) else { return }
        templates.templates[i].tracks = Layout.templateTracks(from: doc.tracks)
    }

    func layoutDiffersFromTemplate(_ doc: RecordingDoc) -> Bool {
        guard let template = templates.template(doc.templateID) else { return false }
        let current = Layout.templateTracks(from: doc.tracks)
        let fitting = template.tracks.filter { $0.channels.allSatisfy { $0 < doc.recording.channels } }
        return current.map(\.channels) != fitting.map(\.channels) || current.map(\.name) != fitting.map(\.name)
    }

    // MARK: Export

    func export(_ doc: RecordingDoc) {
        guard !isExporting else { return }
        guard doc.tracks.contains(where: \.export) else {
            alert("Nothing to export", "Tick at least one track to export.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(doc.recording.name) tracks"
        if let last = UserDefaults.standard.string(forKey: "exportFolder") { panel.directoryURL = URL(fileURLWithPath: last) }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        UserDefaults.standard.set(chosen.path, forKey: "exportFolder")

        var name = Exporter.sanitize(doc.exportName)
        if name.isEmpty { name = doc.recording.datedName }
        let inFolder = nameUse == .folder || nameUse == .both
        let folder = inFolder ? chosen.appendingPathComponent(name, isDirectory: true) : chosen
        if inFolder {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                alert("Export failed", error.localizedDescription)
                return
            }
        }
        let prefix = nameUse == .prefix || nameUse == .both ? name + "_" : ""
        let outputs = Exporter.plan(tracks: doc.tracks, splitStereo: splitStereo, directory: folder, prefix: prefix)
        let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !existing.isEmpty {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = existing.count == 1
                ? "“\(existing[0].url.lastPathComponent)” already exists in this folder."
                : "\(existing.count) of these files already exist in this folder."
            confirm.informativeText = "Replacing them can't be undone."
            confirm.addButton(withTitle: "Cancel")
            confirm.addButton(withTitle: "Replace").hasDestructiveAction = true
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
        }

        let cancel = CancelFlag()
        exportCancel = cancel
        exportPhase = .running(0)
        let recording = doc.recording
        let range = doc.range
        let format = bitDepth.format

        DispatchQueue.global(qos: .userInitiated).async {
            var lastReport = Date.distantPast
            var failure: Error?
            do {
                try Exporter.run(recording: recording, range: range, outputs: outputs, format: format,
                                 isCancelled: { cancel.isCancelled }) { fraction in
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) > 0.05 else { return }
                    lastReport = now
                    DispatchQueue.main.async { if self.isExporting { self.exportPhase = .running(fraction) } }
                }
            } catch { failure = error }

            DispatchQueue.main.async {
                self.exportCancel = nil
                if let failure {
                    self.exportPhase = .idle
                    if !(failure is CancellationError) { self.alert("Export failed", failure.localizedDescription) }
                } else {
                    self.exportPhase = .done(folder: folder, files: outputs.count)
                }
            }
        }
    }

    func cancelExport() { exportCancel?.cancel() }

    // MARK: Keyboard

    /// Space, I and O drive the transport unless a text field is being edited.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
              !(window.firstResponder is NSText), let doc = current else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": player.toggle()
        case "i": doc.setIn(player.position)
        case "o": doc.setOut(player.position)
        default: return false
        }
        return true
    }
}
