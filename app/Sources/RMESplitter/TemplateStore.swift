import Foundation
import SplitterCore

/// Templates live as JSON in Application Support. The first launch seeds them
/// from the .conf layouts bundled with the app.
final class TemplateStore: ObservableObject {
    @Published var templates: [Template] = [] { didSet { if loaded { save() } } }

    private var loaded = false
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RME Splitter", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("templates.json")

        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Template].self, from: data) {
            templates = saved
            loaded = true
        } else {
            loaded = true
            templates = Self.bundled()
        }
    }

    private static func bundled() -> [Template] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Templates"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "conf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? template(fromConf: $0) }
    }

    static func template(fromConf url: URL) throws -> Template {
        let parsed = ConfFormat.parse(try String(contentsOf: url, encoding: .utf8))
        var name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
        if name == "rme-split" { name = "default" }
        if name.hasPrefix("rme-split-") { name.removeFirst("rme-split-".count) }
        return Template(name: name, notes: parsed.notes, tracks: parsed.tracks)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(templates) { try? data.write(to: fileURL, options: .atomic) }
    }

    func template(_ id: UUID?) -> Template? { templates.first { $0.id == id } }

    func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while templates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}
