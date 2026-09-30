import AppKit
import Foundation
import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--cli" {
            Task.detached {
                await runCLI(Array(args.dropFirst()))
                exit(0)
            }
            dispatchMain()
        } else {
            WavNotesApp.main()
        }
    }

    /// wavnotes --cli [--model base|tiny|small|largeTurbo] [--lang en|auto] [--dry-run] [--set-note TEXT] file.wav ...
    static func runCLI(_ args: [String]) async {
        var model = WhisperModel.base
        var language = TranscriptionLanguage.auto
        var dryRun = false
        var fixedNote: String?
        var files: [URL] = []

        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--model":
                let name = it.next() ?? ""
                model = WhisperModel.allCases.first { "\($0)" == name } ?? model
            case "--lang":
                language = TranscriptionLanguage(rawValue: it.next() ?? "") ?? language
            case "--dry-run":
                dryRun = true
            case "--set-note":
                fixedNote = it.next()
            default:
                files.append(URL(fileURLWithPath: arg))
            }
        }

        let transcriber = Transcriber()
        for url in files {
            do {
                if let fixedNote {
                    try IXMLNote.writeNote(fixedNote, to: url)
                    print("\(url.lastPathComponent): \(try IXMLNote.readNote(from: url) ?? "")")
                    continue
                }
                let samples = try AudioLoader.loadFirstSeconds(of: url)
                let text = try await transcriber.transcribe(samples, model: model, language: language)
                if text.isEmpty {
                    print("\(url.lastPathComponent): (no speech, not written)")
                    continue
                }
                if !dryRun { try IXMLNote.writeNote(text, to: url) }
                print("\(url.lastPathComponent): \(text)")
            } catch {
                print("\(url.lastPathComponent): ERROR \(error.localizedDescription)")
            }
        }
    }
}

/// Files handed to the app by Finder (Open With, or dropped on the Dock icon).
/// A publisher so files that arrive before the window exists aren't lost.
final class OpenQueue: ObservableObject {
    static let shared = OpenQueue()
    @Published var urls: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenQueue.shared.urls += urls
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct WavNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Needed when launched as a bare SwiftPM executable rather than a bundled .app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // A single Window (not WindowGroup) so Finder open events feed one list instead of spawning windows.
        Window("WavNotes", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 440)
        }
    }
}
