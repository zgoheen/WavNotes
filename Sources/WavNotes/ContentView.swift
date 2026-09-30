import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    enum Status: Equatable {
        case queued, transcribing, ready, written, noSpeech
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var existingNote: String?
    var transcript = ""
    var status: Status = .queued
}

@MainActor
final class Store: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var modelStatus = ""
    @Published var isBusy = false

    private let transcriber = Transcriber()

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        let wavs = urls.flatMap(Self.expandWavs).filter { !known.contains($0) }
        items += wavs.map { FileItem(url: $0, existingNote: try? IXMLNote.readNote(from: $0)) }
    }

    func process(model: WhisperModel, language: TranscriptionLanguage, autoWrite: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; modelStatus = "" }

        do {
            modelStatus = "Loading \(model.label)…"
            try await transcriber.prepare(model) { fraction in
                Task { @MainActor in self.modelStatus = "Downloading model… \(Int(fraction * 100))%" }
            }
            modelStatus = ""
        } catch {
            modelStatus = "Model failed to load: \(error.localizedDescription)"
            return
        }

        while let i = items.firstIndex(where: { $0.status == .queued }) {
            items[i].status = .transcribing
            let url = items[i].url
            do {
                let samples = try await Task.detached { try AudioLoader.loadFirstSeconds(of: url) }.value
                let text = try await transcriber.transcribe(samples, model: model, language: language)
                guard let j = items.firstIndex(where: { $0.url == url }) else { continue }
                items[j].transcript = text
                items[j].status = text.isEmpty ? .noSpeech : .ready
                if autoWrite, !text.isEmpty { write(j) }
            } catch {
                if let j = items.firstIndex(where: { $0.url == url }) {
                    items[j].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func writeAll() {
        for i in items.indices where items[i].status == .ready {
            write(i)
        }
    }

    func retranscribe(_ id: FileItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = .queued
    }

    private func write(_ i: Int) {
        do {
            try IXMLNote.writeNote(items[i].transcript, to: items[i].url)
            items[i].existingNote = try IXMLNote.readNote(from: items[i].url)
            items[i].status = .written
        } catch {
            items[i].status = .failed("Write failed: \(error.localizedDescription)")
        }
    }

    private static func expandWavs(_ url: URL) -> [URL] {
        let isWav = { (u: URL) in ["wav", "bwf"].contains(u.pathExtension.lowercased()) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return isWav(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).filter(isWav).sorted { $0.path < $1.path }
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @AppStorage("model") private var model: WhisperModel = .base
    @AppStorage("language") private var language: TranscriptionLanguage = .auto
    @AppStorage("autoWrite") private var autoWrite = false
    @State private var isTargeted = false
    @State private var isImporting = false
    @ObservedObject private var openQueue = OpenQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.items.isEmpty {
                dropHint
            } else {
                list
            }
            Divider()
            footer
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.wav, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { addAndProcess(urls) }
        }
        .onReceive(openQueue.$urls) { urls in
            guard !urls.isEmpty else { return }
            openQueue.urls = []
            addAndProcess(urls)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Model", selection: $model) {
                ForEach(WhisperModel.allCases) { Text($0.label).tag($0) }
            }
            .frame(maxWidth: 300)
            Picker("Language", selection: $language) {
                ForEach(TranscriptionLanguage.allCases) { Text($0.label).tag($0) }
            }
            .frame(maxWidth: 200)
            Spacer()
            Toggle("Write automatically", isOn: $autoWrite)
        }
        .disabled(store.isBusy)
        .padding(10)
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Drop WAV files or folders here").font(.title3)
            Text("The first 10 seconds are mixed to mono, transcribed, and written to the iXML Notes field.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach($store.items) { $item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        statusIcon(item.status)
                        Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if case .failed(let msg) = item.status {
                            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                        if item.status == .noSpeech {
                            Text("No speech detected").font(.caption).foregroundStyle(.secondary)
                        }
                        if [.ready, .written, .noSpeech].contains(item.status) || isFailed(item.status) {
                            Button("Redo") {
                                store.retranscribe(item.id)
                                startProcessing()
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.isBusy)
                        }
                    }
                    if let note = item.existingNote, !note.isEmpty {
                        Text("Current note: \(note)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    TextField("Transcript", text: $item.transcript, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(item.status == .queued || item.status == .transcribing)
                        .onChange(of: item.transcript) {
                            if [.written, .noSpeech].contains(item.status), !item.transcript.isEmpty {
                                item.status = .ready
                            }
                        }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button("Remove from List") { store.items.removeAll { $0.id == item.id } }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.isBusy { ProgressView().controlSize(.small) }
            Text(store.modelStatus.isEmpty ? summary : store.modelStatus)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Add Files…") { isImporting = true }
                .disabled(store.isBusy)
            Button("Clear") { store.items.removeAll() }
                .disabled(store.isBusy || store.items.isEmpty)
            Button("Write Notes to Files") { store.writeAll() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.isBusy || !store.items.contains { $0.status == .ready })
        }
        .padding(10)
    }

    private var summary: String {
        let ready = store.items.filter { $0.status == .ready }.count
        let written = store.items.filter { $0.status == .written }.count
        return store.items.isEmpty ? "" : "\(store.items.count) files · \(ready) ready · \(written) written"
    }

    @ViewBuilder
    private func statusIcon(_ status: FileItem.Status) -> some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .transcribing: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "text.bubble").foregroundStyle(.blue)
        case .written: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noSpeech: Image(systemName: "speaker.slash").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func isFailed(_ status: FileItem.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                urls.append(url)
            } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        addAndProcess(urls)
    }

    private func addAndProcess(_ urls: [URL]) {
        store.add(urls)
        startProcessing()
    }

    private func startProcessing() {
        Task { await store.process(model: model, language: language, autoWrite: autoWrite) }
    }
}
