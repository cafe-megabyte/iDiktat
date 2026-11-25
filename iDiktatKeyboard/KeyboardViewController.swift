import AVFoundation
import OSLog
import UIKit

private let log = Logger(subsystem: "de.cafe-megabyte.iDiktat.Keyboard", category: "dictation")

/// Dictation keyboard with two modes (chosen in the iDiktat app):
/// - keyboard mode: records through a hidden web view (`WebAudioCapture`) and transcribes
///   right here with Parakeet TDT v3;
/// - app mode: loads nothing heavy and only sends start/stop to the iDiktat app, which records
///   and transcribes in the background (`AppBridge`).
/// In both modes no audio or text ever leaves the device.
@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let dictateButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let typingKeyboard = TypingKeyboardView()
    private var heightConstraint: NSLayoutConstraint?
    /// Top bar with status and dictate button, in the place of the system's suggestion bar.
    private static let barHeight: CGFloat = 44

    private var mode: AppBridge.Mode?
    private var activity = Activity.idle
    private var insertedAnything = false
    private var lastStatusUpdate = Date.distantPast

    private enum Activity: Equatable {
        case idle
        /// Keyboard mode: recording, or recognizing the rest after Stop.
        case recording, finishing
        /// App mode: the app dictates for us.
        case app(dictation: Int, finishing: Bool)
    }

    // Keyboard mode
    private var capture: WebAudioCapture?
    private let worker = TranscriptionWorker(label: "de.cafe-megabyte.iDiktat.transcription")
    private var modelState = ModelState.unloaded
    private var generation = 0
    private var segmenter = DictationSegmenter()
    private var pendingSegments = 0
    private var capturedSamples = 0

    private enum ModelState: Equatable {
        case unloaded, loading, ready, failed(String)
    }

    // App mode
    private var stateObserver: AppBridge.Observer?
    private var insertedPieces = 0
    private var appWatchdog: Timer?
    private var lastAppStateChange = Date.distantPast

    // Setup status for the app (step 2 there)
    private var reportedFullAccess: Bool?
    private var reportTimer: Timer?

    override func loadView() {
        // An input view that allows the standard keyboard click sound (if enabled in Settings).
        let inputView = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let width = view.bounds.width > 0 ? view.bounds.width : (view.window?.bounds.width ?? 430)
        let landscape = view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
        let height = Self.barHeight + TypingKeyboardView.preferredHeight(width: width, landscape: landscape)
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        typingKeyboard.textDidChange()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The mode may have changed in the app since the keyboard was last shown.
        apply(AppBridge.mode)
        render()
        typingKeyboard.textDidChange()
        reportedFullAccess = nil
        reportSetupStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if let state = UserDefaults(suiteName: AppBridge.appGroup)?.string(forKey: "DebugKeyboardState") {
            typingKeyboard.applyDebugState(state)
        }
        #endif
        reportSetupStatus()
        // While the keyboard appears, iOS is still connecting it to the host app: `hasFullAccess`
        // and the shared container can lag behind by a moment. So check a few more times.
        var checks = 0
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                checks += 1
                guard let self, checks <= 10, self.reportedFullAccess != true else { return timer.invalidate() }
                self.reportSetupStatus()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        reportTimer?.invalidate()
        reportTimer = nil
        switch activity {
        case .recording: capture?.stop()
        case .app(let dictation, false): stopAppDictation(dictation)
        default: break
        }
    }

    deinit {
        MainActor.assumeIsolated {
            capture?.tearDown()
            appWatchdog?.invalidate()
            reportTimer?.invalidate()
        }
    }

    // MARK: - Setup status

    /// Tells the app whether Full Access is granted, so it can show that setup is complete.
    /// Writes only when the value changed or the last write failed. Without Full Access iOS
    /// blocks the write; the app then keeps showing "not confirmed", which is correct.
    private func reportSetupStatus() {
        let fullAccess = hasFullAccess
        guard fullAccess != reportedFullAccess else { return }
        if AppBridge.report(.init(fullAccess: fullAccess, reported: Date())) {
            reportedFullAccess = fullAccess
        }
    }

    // MARK: - Mode

    private func apply(_ newMode: AppBridge.Mode) {
        guard newMode != mode, activity == .idle else { return }
        mode = newMode
        switch newMode {
        case .keyboard:
            stateObserver = nil
            setUpKeyboardMode()
            setStatus(modelState == .ready ? .statusReady : .statusLoadingModel)
        case .app:
            tearDownKeyboardMode()
            stateObserver = AppBridge.Observer(AppBridge.stateNotification) { [weak self] in self?.appStateChanged() }
            setStatus(.statusAppMode)
        }
    }

    private func setUpKeyboardMode() {
        if capture == nil {
            let capture = WebAudioCapture()
            capture.onReady = { [weak self] in self?.render() }
            capture.onStarted = { [weak self] in self?.setStatus(.statusListening) }
            capture.onAudio = { [weak self] data, _ in self?.append(data) }
            capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
            capture.attach(to: view)
            self.capture = capture
        }
        loadModel()
    }

    /// In app mode the keyboard keeps neither the web view nor the model, so it stays tiny.
    private func tearDownKeyboardMode() {
        capture?.tearDown()
        capture = nil
        generation += 1
        if modelState != .unloaded {
            modelState = .unloaded
            worker.unload()
        }
    }

    // MARK: - Keyboard mode: model

    private func loadModel() {
        guard modelState == .unloaded else { return }
        guard let directory = Bundle.main.url(forResource: "Parakeet", withExtension: nil) else {
            modelState = .failed(String(localized: .statusModelMissing))
            setStatus(.statusModelMissing)
            return
        }
        modelState = .loading
        worker.load(from: directory) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.modelState == .loading else { return }
                switch result {
                case .success(let seconds):
                    self.modelState = .ready
                    log.info("model loaded in \(seconds, format: .fixed(precision: 1)) s")
                    self.setStatus(.statusReady)
                case .failure(let error):
                    log.error("model load failed: \(error.localizedDescription, privacy: .public)")
                    self.modelState = .failed(error.localizedDescription)
                    self.setStatus(.Shared.modelLoadFailed(error.localizedDescription))
                }
                self.render()
            }
        }
    }

    // MARK: - Dictate / Stop

    @objc private func toggleDictation() {
        reportSetupStatus()
        switch activity {
        case .idle:
            mode == .app ? startAppDictation() : startKeyboardDictation()
        case .recording:
            capture?.stop()
        case .app(let dictation, false):
            stopAppDictation(dictation)
        case .finishing, .app:
            break
        }
    }

    private func beginInserting() {
        insertedAnything = false
        lastStatusUpdate = .distantPast
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        var text = text
        if !insertedAnything, let before = textDocumentProxy.documentContextBeforeInput,
           let last = before.last, !last.isWhitespace {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
        insertedAnything = true
        typingKeyboard.updateAutoShift()
    }

    // MARK: - Keyboard mode: dictation

    private func startKeyboardDictation() {
        guard hasFullAccess else {
            return setStatus(.statusNeedFullAccess)
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return setStatus(.statusNeedMicrophone)
        }
        guard modelState == .ready, let capture, capture.isReady else { return }

        generation += 1
        segmenter = DictationSegmenter()
        pendingSegments = 0
        capturedSamples = 0
        beginInserting()
        worker.beginDictation()
        activity = .recording
        capture.start()
        setStatus(.statusMicrophoneStarting)
        render()
    }

    private func append(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, activity == .recording else { return }
        capturedSamples += frames
        var samples = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { samples[index] = Float(source[index]) / 32_768 }
        }
        for segment in segmenter.append(samples) { transcribe(segment) }
        showListening(seconds: Double(capturedSamples) / WebAudioCapture.sampleRate)
    }

    private func captureEnded(_ reason: String) {
        log.info("capture ended: \(reason, privacy: .public), \(self.capturedSamples) samples")
        guard activity == .recording else { return }
        if let rest = segmenter.finish() { transcribe(rest) }
        if pendingSegments == 0 {
            activity = .idle
            setStatus(reason == "stopped" ? .statusNothingRecognized : .statusRecordingEnded(reason))
        } else {
            activity = .finishing
            setStatus(.statusRecognizing)
        }
        render()
    }

    private func transcribe(_ samples: [Float]) {
        let generation = generation
        pendingSegments += 1
        worker.transcribe(samples) { [weak self] result in
            MainActor.assumeIsolated { self?.finishedSegment(result, generation: generation) }
        }
    }

    private func finishedSegment(_ result: Result<String, Error>, generation: Int) {
        guard generation == self.generation else { return }
        pendingSegments -= 1
        switch result {
        case .success(let text):
            insert(text)
        case .failure(let error):
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            setStatus(.statusRecognitionFailed(error.localizedDescription))
        }
        if activity == .finishing && pendingSegments == 0 {
            activity = .idle
            if case .success = result { setStatus(insertedAnything ? .statusInserted : .statusNothingRecognized) }
            render()
        }
    }

    // MARK: - App mode: dictation

    private func startAppDictation() {
        guard hasFullAccess else {
            return setStatus(.statusNeedFullAccess)
        }
        guard AppBridge.readState().isSessionAlive else {
            if openApp() {
                setStatus(.statusOpeningApp)
            } else {
                setStatus(.statusOpenAppManually)
            }
            return
        }
        let dictation = Int(Date().timeIntervalSince1970 * 1000)
        activity = .app(dictation: dictation, finishing: false)
        insertedPieces = 0
        beginInserting()
        lastAppStateChange = Date()
        AppBridge.send(.init(dictation: dictation, action: .start))
        setStatus(.statusConnecting)
        startAppWatchdog()
        render()
    }

    private func stopAppDictation(_ dictation: Int) {
        activity = .app(dictation: dictation, finishing: true)
        lastAppStateChange = Date()
        AppBridge.send(.init(dictation: dictation, action: .stop))
        setStatus(.statusRecognizing)
        render()
    }

    private func appStateChanged() {
        guard case .app(let dictation, _) = activity else { return }
        let state = AppBridge.readState()
        guard state.dictation == dictation else { return }
        lastAppStateChange = Date()
        while insertedPieces < state.texts.count {
            insert(state.texts[insertedPieces])
            insertedPieces += 1
        }
        switch state.phase {
        case .listening:
            showListening(seconds: state.seconds)
        case .transcribing:
            setStatus(.statusRecognizing)
        case .finished:
            finishAppDictation(status: insertedAnything ? .statusInserted : .statusNothingRecognized)
        case .failed:
            finishAppDictation(status: .statusAppFailed(state.message ?? String(localized: .unknownError)))
        case .idle:
            break
        }
    }

    private func finishAppDictation(status: LocalizedStringResource) {
        appWatchdog?.invalidate()
        appWatchdog = nil
        activity = .idle
        setStatus(status)
        render()
    }

    /// Notices when the app stopped answering (session ended, app closed in the app switcher, …).
    private func startAppWatchdog() {
        appWatchdog?.invalidate()
        appWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .app = self.activity else { return }
                if !AppBridge.readState().isSessionAlive {
                    self.finishAppDictation(status: .statusSessionEnded)
                } else if Date().timeIntervalSince(self.lastAppStateChange) > 15 {
                    self.finishAppDictation(status: .statusAppNotResponding)
                }
            }
        }
    }

    /// Keyboards may not open apps through public API; walking the responder chain to the
    /// extension's UIApplication is the widely used workaround. Returns false if it is unavailable.
    private func openApp() -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, AppBridge.sessionURL as NSURL, [:] as NSDictionary, nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: - UI

    /// Updated at most twice a second with fixed-width digits, so the text does not flicker.
    private func showListening(seconds: Double) {
        guard Date().timeIntervalSince(lastStatusUpdate) >= 0.5 else { return }
        lastStatusUpdate = Date()
        let whole = Int(seconds)
        setStatus(.statusListeningTime(whole / 60, whole % 60))
    }

    private func configureView() {
        view.backgroundColor = .clear
        let height = view.heightAnchor.constraint(equalToConstant: Self.barHeight + TypingKeyboardView.preferredHeight(width: 430, landscape: false))
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 16, weight: .semibold)
            return attributes
        }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        dictateButton.configuration = config
        dictateButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)

        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: footnote.pointSize, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8

        typingKeyboard.controller = self
        for subview in [statusLabel, dictateButton, typingKeyboard] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            dictateButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            dictateButton.heightAnchor.constraint(equalToConstant: Self.barHeight - 10),
            dictateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: dictateButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: dictateButton.centerYAnchor),

            typingKeyboard.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.barHeight),
            typingKeyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            typingKeyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            typingKeyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The status may shrink, never the button.
        dictateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dictateButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func render() {
        let title: LocalizedStringResource
        let symbol: String
        let color: UIColor
        let enabled: Bool
        switch activity {
        case .recording, .app(_, false):
            (title, symbol, color, enabled) = (.buttonStop, "stop.fill", .systemRed, true)
        case .finishing, .app(_, true):
            (title, symbol, color, enabled) = (.buttonRecognizing, "waveform", .systemGray, false)
        case .idle:
            let ready = mode == .app || (modelState == .ready && capture?.isReady == true)
            (title, symbol, color, enabled) = ready
                ? (.buttonDictate, "mic.fill", .systemBlue, true)
                : (.buttonLoading, "hourglass", .systemGray, false)
        }
        guard var config = dictateButton.configuration else { return }
        config.title = String(localized: title)
        config.image = UIImage(systemName: symbol)
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        // Without this, UIKit cross-fades the title on every change, which looks like flicker.
        UIView.performWithoutAnimation {
            dictateButton.configuration = config
            dictateButton.isEnabled = enabled
            dictateButton.layoutIfNeeded()
        }
    }

    private func setStatus(_ resource: LocalizedStringResource) {
        let text = String(localized: resource)
        guard statusLabel.text != text else { return }
        statusLabel.text = text
    }
}

/// Lets `UIDevice.playInputClick()` play the keyboard click, as the system keyboard does.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
