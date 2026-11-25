import Foundation

/// Owns the Parakeet model and runs all recognition strictly in order on one background queue.
/// Used by the keyboard (keyboard mode) and by the app (app mode, probe dictation).
/// Every completion handler is called on the main thread.
final class TranscriptionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Only touched on `queue`.
    private var transcriber: ParakeetTranscriber?
    /// Decoder context of the current dictation. Only touched on `queue`.
    private var state: ParakeetTranscriber.State?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Loads the model; the completion receives the load time in seconds.
    func load(from directory: URL, completion: @escaping (Result<TimeInterval, Error>) -> Void) {
        queue.async {
            let started = Date()
            let result = Result { try ParakeetTranscriber(modelDirectory: directory) }
            if case .success(let transcriber) = result { self.transcriber = transcriber }
            let outcome = result.map { _ in Date().timeIntervalSince(started) }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Frees the model's memory.
    func unload() {
        queue.async {
            self.transcriber = nil
            self.state = nil
        }
    }

    /// Starts a new dictation, so the next piece is decoded without the previous dictation's context.
    func beginDictation() {
        queue.async { self.state = try? self.transcriber?.makeState() }
    }

    /// Transcribes one piece (at most 15 s) of the current dictation.
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error>
            if let transcriber = self.transcriber, var state = self.state {
                result = Result { try transcriber.transcribe(samples, state: &state) }
                self.state = state
            } else {
                result = .failure(ParakeetTranscriber.TranscriberError.notReady)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
