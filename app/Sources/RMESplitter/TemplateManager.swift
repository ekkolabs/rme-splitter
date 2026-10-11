import SwiftUI
import SplitterCore

struct TemplateManager: View {
    @ObservedObject var store: TemplateStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(store.templates, selection: $selection) { template in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name.isEmpty ? "Untitled" : template.name)
                            Text("\(template.tracks.count) tracks · \(template.channelsNeeded) channels")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Button(action: add) { Image(systemName: "plus") }.help("New template")
                        Button(action: remove) { Image(systemName: "minus") }.help("Delete template")
                            .disabled(selected == nil)
                        Menu {
                            Button("Duplicate", action: duplicate).disabled(selected == nil)
                            Divider()
                            Button("Import .conf File…", action: importConf)
                            Button("Export as .conf File…", action: exportConf).disabled(selected == nil)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 230)
                Divider()
                if let id = selected?.id {
                    TemplateEditor(template: binding(id)).id(id)
                } else {
                    Text("Select a template").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Channels count from 1. Write 3-4 for a stereo pair.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: 540)
        .onAppear { if selected == nil { selection = store.templates.first?.id } }
    }

    private var selected: Template? { store.template(selection) }

    private func binding(_ id: UUID) -> Binding<Template> {
        Binding(get: { store.template(id) ?? Template(name: "") },
                set: { new in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i] = new } })
    }

    private func add() {
        let template = Template(name: store.uniqueName("New Template"), tracks: [TemplateTrack(channels: [0], name: "01_track")])
        store.templates.append(template)
        selection = template.id
    }

    private func remove() {
        guard let i = store.templates.firstIndex(where: { $0.id == selection }) else { return }
        store.templates.remove(at: i)
        selection = store.templates.indices.contains(i) ? store.templates[i].id : store.templates.last?.id
    }

    private func duplicate() {
        guard let source = selected else { return }
        let copy = Template(name: store.uniqueName(source.name + " copy"), notes: source.notes,
                            tracks: source.tracks.map { TemplateTrack(channels: $0.channels, name: $0.name) })
        store.templates.append(copy)
        selection = copy.id
    }

    private func importConf() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose rme-split .conf files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard var template = try? TemplateStore.template(fromConf: url), !template.tracks.isEmpty else { continue }
            template.name = store.uniqueName(template.name)
            store.templates.append(template)
            selection = template.id
        }
    }

    private func exportConf() {
        guard let template = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rme-split-\(template.name).conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ConfFormat.serialize(template).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct TemplateEditor: View {
    @Binding var template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Template name", text: $template.name)
                .font(.title3)
            HStack(spacing: 8) {
                Text("Channels").frame(width: 70, alignment: .leading)
                Text("File name")
            }
            .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($template.tracks) { $track in
                    HStack(spacing: 8) {
                        ChannelField(channels: $track.channels)
                        TextField("Name", text: $track.name)
                        Button {
                            let id = track.id
                            DispatchQueue.main.async { template.tracks.removeAll { $0.id == id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove track")
                    }
                }
                .onMove { template.tracks.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            Button("Add Track") {
                let next = template.channelsNeeded
                template.tracks.append(TemplateTrack(channels: [next], name: String(format: "%02d_track", template.tracks.count + 1)))
            }
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $template.notes)
                .font(.callout)
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        }
        .padding(14)
    }
}

struct ChannelField: View {
    @Binding var channels: [Int]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("1-2", text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(width: 70)
            .focused($focused)
            .onAppear { text = ChannelSpec.format(channels) }
            .onChange(of: channels) { _, new in text = ChannelSpec.format(new) }
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        if let parsed = ChannelSpec.parse(text) { channels = parsed }
        text = ChannelSpec.format(channels)
    }
}
