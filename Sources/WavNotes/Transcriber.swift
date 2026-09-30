import Foundation
import whisper

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case largeTurbo = "ggml-large-v3-turbo-q5_0.bin"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiny: return "Tiny (75 MB, fastest)"
        case .base: return "Base (150 MB)"
        case .small: return "Small (490 MB)"
        case .largeTurbo: return "Large v3 Turbo (570 MB, best)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto, en

    var id: String { rawValue }
    var label: String { self == .auto ? "Auto-detect" : "English" }
}

enum TranscriberError: LocalizedError {
    case modelLoad(String)
    case inference(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoad(let path): return "Could not load Whisper model at \(path)."
        case .inference(let code): return "Whisper failed (code \(code))."
        }
    }
}

/// Owns one loaded whisper.cpp context; reloads only when the model changes.
actor Transcriber {
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WavNotes/models", isDirectory: true)
    }()

    private var context: OpaquePointer?
    private var loadedModel: WhisperModel?

    init() {
        // whisper.cpp logs verbosely to stderr by default.
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let context { whisper_free(context) }
    }

    func prepare(_ model: WhisperModel, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedModel == model, context != nil { return }
        if let context { whisper_free(context) }
        context = nil
        loadedModel = nil

        let file = try await Self.ensureDownloaded(model, progress: progress)
        var params = whisper_context_default_params()
        #if arch(x86_64)
        // Metal on Intel GPUs is unreliable in ggml; the CPU path (AVX2 + Accelerate) is fine for 10 s clips.
        params.use_gpu = false
        #endif
        guard let ctx = whisper_init_from_file_with_params(file.path, params) else {
            throw TranscriberError.modelLoad(file.path)
        }
        context = ctx
        loadedModel = model
    }

    func transcribe(_ samples: [Float], model: WhisperModel, language: TranscriptionLanguage) async throws -> String {
        try await prepare(model)
        guard let context else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.suppress_nst = true
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        let status = language.rawValue.withCString { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(context, params, buf.baseAddress, Int32(buf.count))
            }
        }
        guard status == 0 else { throw TranscriberError.inference(status) }

        let text = (0..<whisper_full_n_segments(context))
            .compactMap { whisper_full_get_segment_text(context, $0).map { String(cString: $0) } }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isLikelyHallucination(text) ? "" : text
    }

    /// Whisper confidently emits these on SFX, room tone, and music, where there is no speech at all.
    private static let hallucinations: Set<String> = [
        "you", "thank you", "thanks", "thanks for watching", "thank you for watching",
        "bye", "okay", "oh", "music", "applause", "silence", "blank_audio",
    ]

    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(.whitespaces).inverted.union(.whitespaces))
        return normalized.isEmpty || hallucinations.contains(normalized)
    }

    // MARK: Model download

    private static func ensureDownloaded(_ model: WhisperModel, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let dest = modelsDirectory.appendingPathComponent(model.rawValue)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let tmp: URL = try await withCheckedThrowingContinuation { cont in
            let observation = ObservationBox()
            let task = URLSession.shared.downloadTask(with: model.downloadURL) { url, response, error in
                observation.value?.invalidate()
                if let error { return cont.resume(throwing: error) }
                guard let url, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: URLError(.badServerResponse))
                }
                // The system deletes `url` when this handler returns, so move it now.
                let kept = dest.appendingPathExtension("part")
                do {
                    try? FileManager.default.removeItem(at: kept)
                    try FileManager.default.moveItem(at: url, to: kept)
                    cont.resume(returning: kept)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation.value = task.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
            task.resume()
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

private final class ObservationBox: @unchecked Sendable {
    var value: NSKeyValueObservation?
}
