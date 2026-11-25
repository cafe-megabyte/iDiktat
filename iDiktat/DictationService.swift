import AVFAudio
import Foundation

/// Speech recognition inside the app.
///
/// In app mode a session keeps the microphone open in the background (otherwise iOS would
/// suspend the app) until it is ended by hand. While it runs, the keyboard sends start/stop
/// through `AppBridge`, and the recognized text goes back the same way. Audio outside a
/// dictation is dropped immediately and never stored.
@MainActor
final class DictationService: ObservableObject {
    static let shared = DictationService()

    @Published var mode = AppBridge.mode {
        didSet {
            AppBridge.mode = mode
            if mode == .keyboard { endSession() }
        }
    }
    @Published private(set) var sessionActive = false
    @Published private(set) var sessionMessage = ""

    private let recorder = MicrophoneRecorder()
    private let worker = TranscriptionWorker(label: "de.cafe-megabyte.iDiktat.app-transcription")
    private var modelRequested = false

    private var commandObserver: AppBridge.Observer?
    private var heartbeat: Timer?
    private var bridgeState = AppBridge.State()

    /// The keyboard's id for the dictation in progress, if any.
    private var dictation: Int?
    private var capturing = false
    private var generation = 0
    private var segmenter = DictationSegmenter()
    private var pendingSegments = 0
    private var capturedSamples = 0
    private var lastPublish = Date.distantPast

    private init() {
        // After a call (or another app using the microphone) iOS recommends whether to resume.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated { self?.resumeAfterInterruption(shouldResume) }
        }
    }

    // MARK: - Session (app mode)

    func startSession() {
        guard !sessionActive else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            sessionMessage = String(localized: .allowMicrophoneFirst)
            return
        }
        do {
            try startMicrophone()
        } catch {
            sessionMessage = String(localized: .microphoneStartFailed(error.localizedDescription))
            return
        }
        loadModelIfNeeded()
        sessionActive = true
        sessionMessage = String(localized: .sessionStarted)
        commandObserver = AppBridge.Observer(AppBridge.commandNotification) { [weak self] in self?.handleCommand() }
        bridgeState = AppBridge.State(heartbeat: Date())
        AppBridge.publish(bridgeState)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bridgeState.heartbeat = Date()
                AppBridge.publish(self.bridgeState)
            }
        }
    }

    func endSession(message: String = String(localized: .sessionEnded)) {
        guard sessionActive else { return }
        heartbeat?.invalidate()
        heartbeat = nil
        commandObserver = nil
        cancelDictation()
        sessionActive = false
        bridgeState = AppBridge.State()
        AppBridge.publish(bridgeState)
        stopMicrophone()
        sessionMessage = message
    }

    private func handleCommand() {
        guard sessionActive, let command = AppBridge.readCommand() else { return }
        switch command.action {
        case .start:
            guard dictation != command.dictation else { return }
            beginDictation(command.dictation)
        case .stop:
            if dictation == command.dictation, capturing { finishDictation() }
        }
    }

    private func resumeAfterInterruption(_ shouldResume: Bool) {
        guard sessionActive else { return }
        recorder.stop()
        do {
            guard shouldResume else { throw CancellationError() }
            try startMicrophone()
        } catch {
            endSession(message: String(localized: .sessionInterrupted))
        }
    }

    // MARK: - Dictation pipeline

    private func beginDictation(_ id: Int) {
        generation += 1
        dictation = id
        capturing = true
        segmenter = DictationSegmenter()
        pendingSegments = 0
        capturedSamples = 0
        worker.beginDictation()
        bridgeState = AppBridge.State(dictation: id, phase: .listening, heartbeat: Date())
        publish()
    }

    private func handle(_ samples: [Float]) {
        guard capturing else { return }
        capturedSamples += samples.count
        for segment in segmenter.append(samples) { transcribe(segment) }
        // Twice a second is plenty for the keyboard's timer and keeps its display calm.
        if Date().timeIntervalSince(lastPublish) >= 0.5 {
            bridgeState.seconds = Double(capturedSamples) / Double(ParakeetTranscriber.sampleRate)
            publish()
        }
    }

    private func finishDictation() {
        guard capturing else { return }
        capturing = false
        if let rest = segmenter.finish() { transcribe(rest) }
        bridgeState.phase = .transcribing
        publish()
        if pendingSegments == 0 { completeDictation() }
    }

    private func cancelDictation() {
        generation += 1
        capturing = false
        dictation = nil
        pendingSegments = 0
    }

    private func transcribe(_ samples: [Float]) {
        let generation = generation
        pendingSegments += 1
        worker.transcribe(samples) { [weak self] result in
            MainActor.assumeIsolated { self?.finishedSegment(result, generation: generation) }
        }
    }

    private func finishedSegment(_ result: Result<String, Error>, generation: Int) {
        guard generation == self.generation, dictation != nil else { return }
        pendingSegments -= 1
        switch result {
        case .success(let text):
            if !text.isEmpty {
                bridgeState.texts.append(text)
                publish()
            }
        case .failure(let error):
            bridgeState.phase = .failed
            bridgeState.message = error.localizedDescription
            publish()
        }
        if !capturing && pendingSegments == 0 { completeDictation() }
    }

    private func completeDictation() {
        guard dictation != nil else { return }
        if bridgeState.phase != .failed { bridgeState.phase = .finished }
        publish()
        dictation = nil
    }

    private func publish() {
        lastPublish = Date()
        bridgeState.heartbeat = Date()
        AppBridge.publish(bridgeState)
    }

    // MARK: - Microphone and model

    private func startMicrophone() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers: music or podcasts keep playing while the session is open.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)
        try recorder.start { [weak self] samples in
            MainActor.assumeIsolated { self?.handle(samples) }
        }
    }

    private func stopMicrophone() {
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func loadModelIfNeeded() {
        guard !modelRequested else { return }
        modelRequested = true
        guard let plugins = Bundle.main.builtInPlugInsURL else { return }
        // The model ships once, inside the keyboard extension. The app reads it from there.
        let directory = plugins.appendingPathComponent("iDiktatKeyboard.appex/Parakeet", isDirectory: true)
        worker.load(from: directory) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .failure(let error) = result else { return }
                self.modelRequested = false
                self.sessionMessage = String(localized: .Shared.modelLoadFailed(error.localizedDescription))
            }
        }
    }
}
