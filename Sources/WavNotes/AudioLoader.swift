import AVFoundation
import Accelerate

enum AudioLoaderError: LocalizedError {
    case empty
    case bufferAllocation
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "File contains no audio."
        case .bufferAllocation: return "Could not allocate audio buffer."
        case .conversion(let msg): return "Resampling failed: \(msg)"
        }
    }
}

enum AudioLoader {
    static let whisperSampleRate = 16_000.0

    /// Reads the first `seconds` of the file, mixes every channel down to mono,
    /// peak-normalizes, and resamples to 16 kHz for Whisper.
    static func loadFirstSeconds(of url: URL, seconds: Double = 10) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))
        guard frameCount > 0 else { throw AudioLoaderError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioLoaderError.bufferAllocation
        }
        try file.read(into: buffer, frameCount: frameCount)

        let mono = mixdown(buffer)
        return try resample(mono, from: format.sampleRate, to: whisperSampleRate)
    }

    /// Averages all channels, then normalizes so quiet or single-channel dialog
    /// in a many-channel poly file isn't buried by the averaging.
    static func mixdown(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return mono }

        for ch in 0..<channels {
            vDSP_vadd(mono, 1, data[ch], 1, &mono, 1, vDSP_Length(frames))
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))

        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(frames))
        if peak > 1e-5 {
            var gain = 0.9 / peak
            vDSP_vsmul(mono, 1, &gain, &mono, 1, vDSP_Length(frames))
        }
        return mono
    }

    static func resample(_ samples: [Float], from inRate: Double, to outRate: Double) throws -> [Float] {
        if inRate == outRate { return samples }
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AudioLoaderError.conversion("unsupported format") }

        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let outCapacity = AVAudioFrameCount(Double(samples.count) * outRate / inRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioLoaderError.bufferAllocation
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw AudioLoaderError.conversion(error?.localizedDescription ?? "unknown error")
        }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}
