import SwiftUI
import SplitterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Files and folders dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) { AppModel.shared.open(urls) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deferred so files passed at launch take priority over the last session.
        DispatchQueue.main.async { AppModel.shared.reopenLast() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RMESplitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("RME Splitter", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.templates)
                .frame(minWidth: 900, minHeight: 580)
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o")
                Button("Export…") { if let doc = model.current { model.export(doc) } }
                    .keyboardShortcut("e")
                    .disabled(model.current == nil || model.isExporting)
            }
            CommandMenu("Templates") {
                Button("Manage Templates…") { model.showingTemplates = true }
                    .keyboardShortcut("t")
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.docs.isEmpty {
                EmptyState()
            } else if model.docs.count == 1 {
                DetailView(doc: model.docs[0], model: model).id(model.docs[0].id)
            } else {
                NavigationSplitView {
                    List(model.docs, selection: $model.selection) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.recording.name).fontWeight(.medium)
                            Text(sidebarSummary(doc.recording)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
                } detail: {
                    if let doc = model.current {
                        DetailView(doc: doc, model: model).id(doc.id)
                    } else {
                        Text("Select a recording").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4).allowsHitTesting(false)
            }
        }
        .overlay {
            if model.isScanning {
                ProgressView("Reading recordings…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $model.showingTemplates) { TemplateManager(store: model.templates) }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil },
                                                      set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onReceive(model.player.$error) { message in
            guard let message else { return }
            model.player.error = nil
            model.alert("Playback", message)
        }
    }

    private func sidebarSummary(_ rec: Recording) -> String {
        var bits = ["\(rec.channels) ch", Timecode.short(seconds: rec.duration)]
        if let created = rec.created { bits.insert(created.formatted(date: .numeric, time: .omitted), at: 0) }
        if rec.parts.count > 1 { bits.append("\(rec.parts.count) parts") }
        bits.append(ByteCountFormatter.string(fromByteCount: Int64(rec.totalBytes), countStyle: .file))
        return bits.joined(separator: " · ")
    }
}

struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a folder or a WAV file")
                .font(.title2.weight(.semibold))
            Text("Recordings split across several files are joined automatically.")
                .foregroundStyle(.secondary)
            Button("Open…") { model.openPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.quaternary)
                .padding(24)
        }
    }
}
