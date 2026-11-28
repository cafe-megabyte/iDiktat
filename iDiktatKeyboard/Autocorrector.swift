import NaturalLanguage
import UIKit

/// Decides, for one just-completed word, whether to replace it with a bilingual (German/English)
/// spelling correction — see PROJ-3 spec/design — and remembers that one replacement so an
/// immediate undo (the delete key, right after) can revert it and learn the rejection.
/// `TypingKeyboardView` owns the actual text editing (it has the `UITextDocumentProxy`); this
/// type only decides *what* to type and tracks the undo/learn state.
final class Autocorrector {
    private let checker = UITextChecker()
    /// Set by `correct(word:contextBefore:)` right after a replacement; consumed by
    /// `undoIfPending()`, or cleared by `clearPending()` once anything else happens.
    /// The separator (space/punctuation/newline) is set by `setSeparator()` before it is
    /// inserted, so the undo path knows how much to delete and re-insert.
    private var pending: (original: String, corrected: String)?
    private var pendingSeparator: String?

    /// Returns the corrected spelling for `word`, or `nil` if nothing should change — either
    /// because `word` is already valid in German or English (AC-2), or because neither language
    /// offers a usable correction. `contextBefore` is the text right before `word`, used only to
    /// break a tie when both languages offer a correction (AC-4). On a replacement, remembers it
    /// (AC-6/AC-7); on no replacement, clears any earlier pending state, same as `clearPending()`.
    func correct(word: String, contextBefore: String) -> String? {
        guard !isValid(word, language: "de_DE"), !isValid(word, language: "en_US") else {
            pending = nil
            return nil
        }

        let germanGuess = firstGuess(for: word, language: "de_DE")
        let englishGuess = firstGuess(for: word, language: "en_US")

        let chosen: String?
        switch (germanGuess, englishGuess) {
        case (nil, nil):
            chosen = nil
        case (let german?, nil):
            chosen = german
        case (nil, let english?):
            chosen = english
        case (let german?, let english?):
            chosen = pickCandidate(german: german, english: english, word: word, contextBefore: contextBefore)
        }

        guard let chosen, chosen.lowercased() != word.lowercased() else {
            pending = nil
            return nil
        }
        let corrected = applyCapitalization(of: word, to: chosen)
        pending = (original: word, corrected: corrected)
        return corrected
    }

    /// Call when any key other than an immediate following backspace is pressed, so a later
    /// backspace no longer undoes a now-stale correction.
    func clearPending() {
        pending = nil
        pendingSeparator = nil
    }

    /// Call before inserting the separator (space/punctuation/newline), so the undo path knows
    /// how much text to delete and re-insert.
    func setSeparator(_ separator: String) {
        guard pending != nil else { return }
        pendingSeparator = separator
    }

    /// Call when the delete key is pressed. If a correction is pending, consumes it, learns the
    /// rejected word (AC-7), and returns a tuple so the caller can replace the still-visible
    /// `corrected + separator` text with `original + separator` (AC-6). Returns `nil` when there
    /// is nothing to undo — the caller then deletes normally.
    func undoIfPending() -> (original: String, corrected: String, separator: String)? {
        guard let pending else { return nil }
        let separator = pendingSeparator ?? ""
        self.pending = nil
        self.pendingSeparator = nil
        AppBridge.learnException(pending.original)
        return (original: pending.original, corrected: pending.corrected, separator: separator)
    }

    private func isValid(_ word: String, language: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location
            == NSNotFound
    }

    private func firstGuess(for word: String, language: String) -> String? {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        guard misspelled.location != NSNotFound else { return nil }
        guard let guess = checker.guesses(forWordRange: misspelled, in: word, language: language)?.first else { return nil }
        // EC-2: reconstruct the word by replacing only the misspelled range, preserving any prefix/suffix.
        let prefix = (word as NSString).substring(to: misspelled.location)
        let suffix = (word as NSString).substring(from: misspelled.location + misspelled.length)
        return prefix + guess + suffix
    }

    /// AC-4: prefer the candidate matching the dominant language of the preceding text; with no
    /// clear signal (e.g. the first word of a message, EC-6), prefer whichever candidate is
    /// closer to the typed word — German wins on an exact tie, since it's the fixed layout.
    private func pickCandidate(german: String, english: String, word: String, contextBefore: String) -> String {
        let trimmed = contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let dominant = NLLanguageRecognizer.dominantLanguage(for: trimmed) {
            if dominant == .german { return german }
            if dominant == .english { return english }
        }
        let germanDistance = levenshtein(word.lowercased(), german.lowercased())
        let englishDistance = levenshtein(word.lowercased(), english.lowercased())
        return germanDistance <= englishDistance ? german : english
    }

    /// AC-5: an all-uppercase or capitalized original keeps that pattern on the correction.
    private func applyCapitalization(of original: String, to candidate: String) -> String {
        if original.count > 1, original == original.uppercased() {
            return candidate.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        return candidate
    }

    /// Classic edit distance between two short words.
    private func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : min(previous[j - 1] + 1, previous[j] + 1, current[j - 1] + 1)
            }
            previous = current
        }
        return previous[b.count]
    }
}
