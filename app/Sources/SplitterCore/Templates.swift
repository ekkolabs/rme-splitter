import Foundation

/// A track in the working layout: one channel (mono) or two (stereo pair).
/// Channel indexes are 0-based, as in the rme-split .conf files.
public struct Track: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var channels: [Int]
    public var name: String
    public var export = true
    public var mute = false
    public var solo = false

    public init(channels: [Int], name: String, export: Bool = true) {
        self.channels = channels
        self.name = name
        self.export = export
    }

    public var isStereo: Bool { channels.count == 2 }
}

public struct TemplateTrack: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var channels: [Int]
    public var name: String

    public init(channels: [Int], name: String) {
        self.channels = channels
        self.name = name
    }
}

public struct Template: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var notes: String
    public var tracks: [TemplateTrack]

    public init(name: String, notes: String = "", tracks: [TemplateTrack] = []) {
        self.name = name
        self.notes = notes
        self.tracks = tracks
    }

    /// Channels a recording needs for every track of this template to apply.
    public var channelsNeeded: Int { (tracks.flatMap(\.channels).max() ?? -1) + 1 }
}

/// Channel numbers as shown in the UI: 1-based, "5" or "3-4".
public enum ChannelSpec {
    public static func format(_ channels: [Int]) -> String {
        channels.map { String($0 + 1) }.joined(separator: "–")
    }

    public static func parse(_ text: String) -> [Int]? {
        let parts = text.split(whereSeparator: { "-–—/,+ ".contains($0) })
        guard (1...2).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let v = Int(p), v >= 1, v <= 512 else { return nil }
            out.append(v - 1)
        }
        if out.count == 2, out[0] == out[1] { return nil }
        return out
    }
}

public enum Layout {
    public static func channelName(_ channel: Int) -> String {
        String(format: "ch_%02d", channel + 1)
    }

    public static func mono(channelCount: Int) -> [Track] {
        (0..<channelCount).map { Track(channels: [$0], name: channelName($0)) }
    }

    /// Template tracks first, then any channels the template doesn't mention
    /// as mono tracks left out of the export. `dropped` counts template tracks
    /// that need channels the recording doesn't have.
    public static func apply(_ template: Template, channelCount: Int) -> (tracks: [Track], dropped: Int) {
        var tracks: [Track] = []
        var used = Set<Int>()
        var dropped = 0
        for t in template.tracks {
            guard !t.channels.isEmpty, t.channels.allSatisfy({ $0 >= 0 && $0 < channelCount }) else {
                dropped += 1
                continue
            }
            tracks.append(Track(channels: t.channels, name: t.name))
            used.formUnion(t.channels)
        }
        for c in 0..<channelCount where !used.contains(c) {
            tracks.append(Track(channels: [c], name: channelName(c), export: false))
        }
        return (tracks, dropped)
    }

    public static func templateTracks(from tracks: [Track]) -> [TemplateTrack] {
        tracks.filter(\.export).map { TemplateTrack(channels: $0.channels, name: $0.name) }
    }
}

/// The `CHANNELS  OUTPUT_NAME` text format used by the rme-split CLI.
public enum ConfFormat {
    private static let boilerplate = [
        "rme-split channel layout config", "Edit this file to change", "Format:", "CHANNELS:", "OUTPUT_NAME:",
        "Lines starting with #",
    ]

    public static func parse(_ text: String) -> (tracks: [TemplateTrack], notes: String) {
        var tracks: [TemplateTrack] = []
        var notes: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let comment = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !comment.isEmpty, !boilerplate.contains(where: { comment.hasPrefix($0) }) { notes.append(comment) }
                continue
            }
            guard let gap = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let name = line[gap...].trimmingCharacters(in: .whitespaces)
            let channels = line[..<gap].split(separator: "-").compactMap { Int($0) }
            guard !name.isEmpty, (1...2).contains(channels.count), channels.allSatisfy({ $0 >= 0 }) else { continue }
            tracks.append(TemplateTrack(channels: channels, name: name))
        }
        return (tracks, notes.joined(separator: "\n"))
    }

    public static func serialize(_ template: Template) -> String {
        var out = """
        # rme-split channel layout config
        # Edit this file to change channel routing and output filenames.
        #
        # Format:  CHANNELS    OUTPUT_NAME
        #   CHANNELS:    single number = mono, N-M = stereo pair (0-indexed)
        #   OUTPUT_NAME: output filename without .wav (spaces allowed)
        #
        # Lines starting with # and blank lines are ignored.

        """
        for line in template.notes.components(separatedBy: .newlines) where !line.isEmpty {
            out += "# \(line)\n"
        }
        out += "\n"
        for t in template.tracks {
            let spec = t.channels.map(String.init).joined(separator: "-")
            out += spec.padding(toLength: max(8, spec.count + 1), withPad: " ", startingAt: 0) + t.name + "\n"
        }
        return out
    }
}
