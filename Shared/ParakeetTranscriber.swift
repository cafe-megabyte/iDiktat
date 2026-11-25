import CoreML
import Foundation

/// Offline speech-to-text with NVIDIA Parakeet TDT 0.6B v3 (Core ML conversion by FluidInference).
///
/// Only Core ML and Foundation are used. The model is read from a local folder inside the
/// app bundle; this type contains no networking code and never downloads anything.
///
/// The model works on fixed 15-second windows of 16 kHz mono audio. Longer recordings are
/// transcribed window by window with `transcribe(_:state:)`; passing the same `State` keeps
/// the decoder's language context across windows.
///
/// Decoding follows the greedy TDT algorithm used by FluidAudio (Apache-2.0), see
/// THIRD_PARTY_NOTICES.md.
///
/// All stored properties are immutable after `init`; callers use one instance from one serial queue.
final class ParakeetTranscriber: @unchecked Sendable {
    static let sampleRate = 16_000
    /// Samples per model window (15 s). The preprocessor input has exactly this length.
    static let windowSamples = 240_000
    /// Audio samples per encoder frame (80 ms).
    static let samplesPerFrame = 1_280

    enum TranscriberError: LocalizedError {
        case missingFile(String)
        case badModelOutput(String)
        case notReady

        var errorDescription: String? {
            switch self {
            case .missingFile(let name): String(localized: .Shared.modelFileMissing(name))
            case .badModelOutput(let name): String(localized: .Shared.unexpectedModelOutput(name))
            case .notReady: String(localized: .Shared.modelNotReady)
            }
        }
    }

    /// Decoder state carried from one window to the next within a dictation.
    struct State {
        fileprivate var hidden: MLMultiArray
        fileprivate var cell: MLMultiArray
        /// Prediction-network output for the last emitted token (or the start symbol).
        fileprivate var predictorOutput: MLMultiArray?
        /// True until the first text of this dictation has been produced.
        fileprivate(set) var isAtStart = true
    }

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel

    private let pieces: [String]
    /// Tokens the decoder may emit. Restricts output to Latin script (German and English),
    /// so similar-sounding Cyrillic or Greek pieces are never chosen.
    private let allowed: [Bool]

    private let blankId = 8192
    private let durationBins = [0, 1, 2, 3, 4]
    private let encoderHidden = 1024
    private let decoderHidden = 640

    init(modelDirectory: URL) throws {
        func url(_ name: String) throws -> URL {
            let url = modelDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw TranscriberError.missingFile(name) }
            return url
        }
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: url(name), configuration: configuration)
        }
        // Same placement as FluidAudio: the mel frontend is CPU-only, the rest prefers the Neural Engine.
        preprocessor = try load("Preprocessor.mlmodelc", .cpuOnly)
        encoder = try load("Encoder_v2.mlmodelc", .cpuAndNeuralEngine)
        decoder = try load("Decoder.mlmodelc", .cpuAndNeuralEngine)
        joint = try load("JointDecisionv3.mlmodelc", .cpuAndNeuralEngine)

        let data = try Data(contentsOf: url("parakeet_vocab.json"))
        let vocabulary = try JSONDecoder().decode([String: String].self, from: data)
        var pieces = Array(repeating: "", count: blankId)
        for (key, piece) in vocabulary {
            if let id = Int(key), id >= 0, id < blankId { pieces[id] = piece }
        }
        self.pieces = pieces
        allowed = pieces.map(Self.isGermanOrEnglish)
    }

    func makeState() throws -> State {
        let hidden = try MLMultiArray(shape: [2, 1, NSNumber(value: decoderHidden)], dataType: .float32)
        let cell = try MLMultiArray(shape: [2, 1, NSNumber(value: decoderHidden)], dataType: .float32)
        hidden.fill(0)
        cell.fill(0)
        return State(hidden: hidden, cell: cell)
    }

    /// Transcribes up to 15 s of 16 kHz mono audio in the range -1...1.
    /// Returns the text of this window; a leading space marks a word boundary to the previous window.
    func transcribe(_ samples: [Float], state: inout State) throws -> String {
        let count = min(samples.count, Self.windowSamples)
        guard count >= Self.samplesPerFrame else { return "" }

        // 1. Mel spectrogram. The input is zero-padded to the fixed window; audio_length marks the real end.
        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let audioPointer = audio.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
        audioPointer.initialize(repeating: 0, count: Self.windowSamples)
        samples.withUnsafeBufferPointer { audioPointer.update(from: $0.baseAddress!, count: count) }
        let mel = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio,
            "audio_length": try Self.scalar(Int32(count)),
        ]))

        // 2. Acoustic encoder: [1, 1024, 188] frames of 80 ms.
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": try Self.feature(mel, "mel"),
            "mel_length": try Self.feature(mel, "mel_length"),
        ]))
        let frames = try Self.feature(encoded, "encoder")
        let encodedLength = try Self.feature(encoded, "encoder_length")[0].intValue
        let usableFrames = min(encodedLength, frames.shape[2].intValue, (count + Self.samplesPerFrame - 1) / Self.samplesPerFrame)

        // 3. Greedy TDT decoding.
        let tokens = try decode(frames: frames, frameCount: usableFrames, state: &state)
        var text = tokens.map { pieces[$0] }
            .filter { !($0.hasPrefix("<") && $0.hasSuffix(">")) }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
        if state.isAtStart {
            text = String(text.drop(while: { $0 == " " }))
            if !text.isEmpty { state.isAtStart = false }
        }
        return text
    }

    // MARK: - TDT decoding

    private func decode(frames: MLMultiArray, frameCount: Int, state: inout State) throws -> [Int] {
        guard frameCount > 0 else { return [] }
        let encoderStep = try MLMultiArray(shape: [1, NSNumber(value: encoderHidden), 1], dataType: .float32)
        let target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let targetLength = try Self.scalar(1)

        func runDecoder(_ token: Int) throws {
            target[0] = NSNumber(value: token)
            let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "targets": target, "target_length": targetLength, "h_in": state.hidden, "c_in": state.cell,
            ]))
            state.predictorOutput = try Self.feature(output, "decoder")
            state.hidden = try Self.feature(output, "h_out")
            state.cell = try Self.feature(output, "c_out")
        }

        // The blank symbol doubles as start-of-sequence and primes the prediction network.
        if state.predictorOutput == nil { try runDecoder(blankId) }

        let frameStride = frames.strides[1].intValue
        let timeStride = frames.strides[2].intValue
        let source = frames.dataPointer.bindMemory(to: Float.self, capacity: frames.count)
        let stepStride = encoderStep.strides[1].intValue
        let destination = encoderStep.dataPointer.bindMemory(to: Float.self, capacity: encoderStep.count)

        var tokens: [Int] = []
        var time = 0
        var lastEmissionTime = -1
        var emissionsAtTime = 0
        while time < frameCount {
            for index in 0..<encoderHidden {
                destination[index * stepStride] = source[index * frameStride + time * timeStride]
            }
            let (token, durationBin) = try runJoint(encoderStep: encoderStep, decoderStep: state.predictorOutput!)
            var duration = durationBins[min(max(durationBin, 0), durationBins.count - 1)]

            if token == blankId {
                time += max(duration, 1)
                continue
            }

            tokens.append(token)
            try runDecoder(token)

            if time == lastEmissionTime {
                emissionsAtTime += 1
            } else {
                lastEmissionTime = time
                emissionsAtTime = 1
            }
            // Stop the decoder from emitting endlessly on one frame.
            if duration == 0 && emissionsAtTime >= 2 { duration = 1 }
            time += duration
        }
        return tokens
    }

    private func runJoint(encoderStep: MLMultiArray, decoderStep: MLMultiArray) throws -> (token: Int, durationBin: Int) {
        let output = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": encoderStep, "decoder_step": decoderStep,
        ]))
        var token = try Self.feature(output, "token_id")[0].intValue
        let durationBin = try Self.feature(output, "duration")[0].intValue

        if token != blankId, !(token >= 0 && token < blankId && allowed[token]) {
            // Fall back to the best-scoring German/English candidate (or blank) among the top 64.
            let ids = try Self.feature(output, "top_k_ids")
            let logits = try Self.feature(output, "top_k_logits")
            var best = blankId
            var bestLogit = -Float.infinity
            for index in 0..<ids.count {
                let id = ids[index].intValue
                let logit = logits[index].floatValue
                let usable = id == blankId || (id >= 0 && id < blankId && allowed[id])
                if usable && logit > bestLogit {
                    best = id
                    bestLogit = logit
                }
            }
            token = best
        }
        return (token, durationBin)
    }

    // MARK: - Helpers

    /// A piece is allowed when every letter in it is Latin (incl. ä, ö, ü, ß and accented letters).
    private static func isGermanOrEnglish(_ piece: String) -> Bool {
        if piece.isEmpty { return false }
        for scalar in piece.unicodeScalars where scalar.properties.isAlphabetic {
            let value = scalar.value
            let latin = value < 0x0250 || (0x1E00...0x1EFF).contains(value)
            if !latin { return false }
        }
        return true
    }

    private static func scalar(_ value: Int32) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array[0] = NSNumber(value: value)
        return array
    }

    private static func feature(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw TranscriberError.badModelOutput(name)
        }
        return value
    }
}

private extension MLMultiArray {
    func fill(_ value: Float) {
        let pointer = dataPointer.bindMemory(to: Float.self, capacity: count)
        pointer.initialize(repeating: value, count: count)
    }
}
