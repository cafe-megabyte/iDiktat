import Foundation

/// Splits a growing 16 kHz recording into pieces the model can handle (at most 15 s each).
///
/// Each cut is placed at the quietest 100 ms between 8 s and 14 s into the pending audio,
/// which is usually a pause between words, so words are rarely split in half.
struct DictationSegmenter {
    private static let rate = ParakeetTranscriber.sampleRate
    private static let earliestCut = 8 * rate
    private static let latestCut = 14 * rate
    private static let probe = rate / 10

    private(set) var pending: [Float] = []

    /// Adds audio and returns any segments that are now complete.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var ready: [[Float]] = []
        while pending.count >= Self.latestCut + Self.probe {
            let cut = quietestPoint()
            ready.append(Array(pending[..<cut]))
            pending.removeFirst(cut)
        }
        return ready
    }

    /// Returns the remaining audio at the end of a dictation (nil if it is too short to hold speech).
    mutating func finish() -> [Float]? {
        defer { pending = [] }
        return pending.count >= Self.rate / 4 ? pending : nil
    }

    private func quietestPoint() -> Int {
        var bestStart = Self.latestCut - Self.probe
        var bestEnergy = Float.infinity
        var start = Self.earliestCut
        while start + Self.probe <= Self.latestCut {
            var energy: Float = 0
            for index in start..<(start + Self.probe) { energy += pending[index] * pending[index] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += Self.probe / 2
        }
        return bestStart + Self.probe / 2
    }
}
