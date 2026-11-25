import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var text = ""
    @State private var testFieldFocused = false
    /// "Check Now" opened the keyboard and waits for its confirmation.
    @State private var checking = false
    @ObservedObject private var service = DictationService.shared
    @StateObject private var keyboard = KeyboardSetup()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                Form {
                    Section {
                        LabeledContent { Text(microphoneLabel) } label: { Text(.microphoneAccess) }
                        if microphone != .granted {
                            Button(.allowMicrophone, action: requestMicrophone)
                        }
                    } header: {
                        Text(.microphoneSection)
                    }

                    keyboardSection(scroller)

                    recognitionSection

                    Section {
                        TestTextView(text: $text, isFocused: $testFieldFocused,
                                     placeholder: String(localized: .testFieldPlaceholder))
                            .id(testFieldID)
                        Text(.tryItHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text(.tryItSection)
                    }
                }
                .navigationTitle(Text(verbatim: "iDiktat"))
                #if DEBUG
                .onAppear {
                    // For keyboard screenshots in the simulator: launch with -FocusTestField YES.
                    if UserDefaults.standard.bool(forKey: "FocusTestField") {
                        testFieldFocused = true
                        scroller.scrollTo(testFieldID, anchor: .top)
                    }
                }
                #endif
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings.
            if phase == .active {
                keyboard.refresh()
                microphone = AVAudioApplication.shared.recordPermission
            }
        }
        .onChange(of: keyboard.status) { _, status in
            // Confirmed: close the keyboard that "Check Now" opened.
            if status == .ready && checking {
                checking = false
                testFieldFocused = false
            }
        }
        .onChange(of: testFieldFocused) { _, focused in
            // Keyboard closed without a confirmation: drop the hint.
            if !focused { checking = false }
        }
    }

    private let testFieldID = "testField"

    private func keyboardSection(_ scroller: ScrollViewProxy) -> some View {
        Section {
            switch keyboard.status {
            case .ready:
                Label(.keyboardReady, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notAdded:
                LabeledContent { Text(.keyboardNotAdded) } label: { Text(.keyboardLabel) }
                Text(.addKeyboardSteps)
            case .awaitingFullAccess:
                LabeledContent { Text(.fullAccessUnconfirmed) } label: { Text(.fullAccessLabel) }
                Text(.fullAccessSteps)
                Button(.checkNow) {
                    checking = true
                    testFieldFocused = true
                    withAnimation { scroller.scrollTo(testFieldID, anchor: .center) }
                }
                if checking {
                    Text(.checkingHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if keyboard.status != .ready {
                Button(.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text(.keyboardSection)
        } footer: {
            Text(.keyboardFooter)
        }
    }

    private var recognitionSection: some View {
        Section {
            Picker(selection: $service.mode) {
                Text(.modeKeyboard).tag(AppBridge.Mode.keyboard)
                Text(.modeApp).tag(AppBridge.Mode.app)
            } label: {
                Text(.recognitionPicker)
            }
            .pickerStyle(.segmented)

            if service.mode == .app {
                LabeledContent {
                    Text(service.sessionActive ? .sessionRunning : .sessionStopped)
                } label: {
                    Text(.sessionLabel)
                }
                if service.sessionActive {
                    Button(.endSession, role: .destructive) { service.endSession() }
                } else {
                    Button(.startSession) { service.startSession() }
                        .disabled(microphone != .granted)
                }
                if !service.sessionMessage.isEmpty {
                    Text(verbatim: service.sessionMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(.recognitionSection)
        } footer: {
            switch service.mode {
            case .keyboard:
                Text(.keyboardModeFooter)
            case .app:
                Text(.appModeFooter)
            }
        }
    }

    private var microphoneLabel: LocalizedStringResource {
        switch microphone {
        case .granted: .microphoneGranted
        case .denied: .microphoneDenied
        default: .microphoneUndetermined
        }
    }

    private func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async { microphone = AVAudioApplication.shared.recordPermission }
        }
    }
}
