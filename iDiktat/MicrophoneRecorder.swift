import AVFAudio
import Foundation

/// Records the microphone in the app and delivers 16 kHz mono Float samples on the main thread.
final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false
    private var onSamples: (([Float]) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    init() {
        // Plugging in headphones or connecting AirPods stops the engine; pick up the new microphone.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning, let onSamples = self.onSamples else { return }
            self.stop()
            try? self.start(onSamples: onSamples)
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Starts recording. `onSamples` is called on the main thread with 16 kHz mono audio.
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        guard !isRunning else { return }
        self.onSamples = onSamples
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetTranscriber.sampleRate), channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.unsupportedFormat
        }

        let tap: AVAudioNodeTapBlock = { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: output, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            DispatchQueue.main.async { onSamples(samples) }
        }
        // iOS 27 replaces installTap(onBus:bufferSize:format:block:) with a variant that reports errors.
        // The SDK imports it only under this name (NS_REFINED_FOR_SWIFT without a Swift wrapper);
        // the error parameter becomes `throws`, `error: ()` is the placeholder the importer leaves behind.
        try input.__installTap(onBus: 0, bufferSize: 4096, format: inputFormat, error: (), block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    enum RecorderError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { String(localized: .unsupportedAudioFormat) }
    }
}
