import UIKit

/// A full typing keyboard modelled on the iOS 27 system keyboard (German QWERTZ or English
/// QWERTY, following the iPhone's language), so short corrections need no keyboard switch.
///
/// Geometry is measured from the system keyboard on an iPhone 15 Pro Max (430 pt wide) and
/// scales with the width, so smaller iPhones get the same proportions.
///
/// Touches are handled here centrally rather than by one control per key. That gives the
/// system keyboard's feel: keys react across the gaps, several fingers can type at once, you
/// can slide from key to key, long-press for accents, and long-press the space bar to move
/// the cursor.
final class TypingKeyboardView: UIView {
    // MARK: Model

    enum Language {
        case german, english

        /// Follows the language iOS chose for the keyboard's texts (German or English), so the
        /// layout always matches the localized labels.
        static var current: Language {
            Bundle.main.preferredLocalizations.first == "de" ? .german : .english
        }
    }

    enum Page { case letters, numbers, symbols }
    enum Shift { case off, once, locked }

    enum Kind: Equatable {
        case character(String)
        case shift, delete, space, returnKey, globe
        case page(Page)
    }

    /// The controller provides the text proxy, the keyboard switcher and the click sound.
    weak var controller: UIInputViewController?

    private(set) var language = Language.current
    private(set) var page = Page.letters
    private(set) var shift = Shift.off

    private var keys: [KeyView] = []
    private let globeButton = UIButton(type: .system)
    private let popup = KeyPopupView()

    // Geometry, measured on the iPhone 15 Pro Max (all in points at 430 pt width).
    private struct Metrics {
        var side: CGFloat, gap: CGFloat, keyHeight: CGFloat, rowGap: CGFloat
        var top: CGFloat, bottom: CGFloat
        var letterFont: CGFloat, labelFont: CGFloat, showsPreview: Bool

        init(width: CGFloat, landscape: Bool) {
            let scale = min(width, 430) / 430
            side = 6.67 * scale
            gap = 6 * scale
            keyHeight = landscape ? 33 : (width >= 400 ? 45 : 42)
            rowGap = landscape ? 6 : 11
            top = landscape ? 4 : 8
            bottom = landscape ? 4 : 7
            letterFont = landscape ? 20 : 22
            labelFont = landscape ? 16 : 17.5
            showsPreview = !landscape
        }

        var height: CGFloat { top + 4 * keyHeight + 3 * rowGap + bottom }
    }

    private var metrics = Metrics(width: 430, landscape: false)

    /// Height the keyboard needs at the given width.
    static func preferredHeight(width: CGFloat, landscape: Bool) -> CGFloat {
        Metrics(width: width, landscape: landscape).height
    }

    // MARK: Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        clipsToBounds = false

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.backgroundColor = KeyView.keyColor
        globeButton.layer.cornerRadius = KeyView.cornerRadius
        globeButton.addTarget(self, action: #selector(globeEvent(_:with:)), for: .allTouchEvents)
        addSubview(globeButton)

        popup.isHidden = true
        addSubview(popup)
        rebuildKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func globeEvent(_ sender: UIButton, with event: UIEvent) {
        controller?.handleInputModeList(from: sender, with: event)
    }

    /// Call when the text or the field changed (cursor moved, other field, …).
    func textDidChange() {
        updateReturnKey()
        updateAutoShift()
    }

    #if DEBUG
    /// Screenshot states for the simulator, where nobody can tap: "numbers", "symbols",
    /// "lower", "caps", "english", "preview-q", "accents-a". Debug builds only.
    func applyDebugState(_ state: String) {
        for part in state.split(separator: ",").map(String.init) {
            switch part {
            case "english": language = .english; rebuildKeys()
            case "numbers": setPage(.numbers)
            case "symbols": setPage(.symbols)
            case "lower": setShift(.off)
            case "caps": setShift(.locked)
            default:
                layoutIfNeeded()
                if part.hasPrefix("preview-"), let key = keys.first(where: { $0.kind == .character(String(part.dropFirst(8))) }) {
                    showPreview(for: key)
                } else if part.hasPrefix("accents-"), let key = keys.first(where: { $0.kind == .character(String(part.dropFirst(8))) }),
                          case .character(let c) = key.kind {
                    popup.showAccents(Accents.variants(for: c, language: language), above: key.frame, in: bounds, font: metrics.letterFont)
                }
            }
        }
    }
    #endif

    // MARK: Layouts

    private var rows: [[Kind]] {
        func chars(_ s: String) -> [Kind] { s.map { .character(String($0)) } }
        let showsGlobe = controller?.needsInputModeSwitchKey ?? false
        let bottom: [Kind] = showsGlobe
            ? [.page(page == .letters ? .numbers : .letters), .globe, .space, .returnKey]
            : [.page(page == .letters ? .numbers : .letters), .space, .returnKey]
        switch page {
        case .letters where language == .german:
            return [chars("qwertzuiopü"), chars("asdfghjklöä"), [.shift] + chars("yxcvbnm") + [.delete], bottom]
        case .letters:
            return [chars("qwertyuiop"), chars("asdfghjkl"), [.shift] + chars("zxcvbnm") + [.delete], bottom]
        case .numbers:
            let currency = language == .german ? "€" : "$"
            return [chars("1234567890"), chars("-/:;()\(currency)&@\""),
                    [.page(.symbols)] + chars(".,?!'") + [.delete], bottom]
        case .symbols:
            let currencies = language == .german ? "$£¥" : "€£¥"
            return [chars("[]{}#%^*+="), chars("_\\|~<>\(currencies)•"),
                    [.page(.numbers)] + chars(".,?!'") + [.delete], bottom]
        }
    }

    private func rebuildKeys() {
        keys.forEach { $0.removeFromSuperview() }
        keys = rows.flatMap { $0 }.filter { $0 != .globe }.map { KeyView(kind: $0) }
        for key in keys { insertSubview(key, belowSubview: popup) }
        updateLabels()
        updateReturnKey()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let landscape = (window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape) ?? (bounds.width > 600)
        metrics = Metrics(width: bounds.width, landscape: landscape)
        let m = metrics
        let inner = bounds.width - 2 * m.side
        let rows = rows
        // Letter width: the widest row (11 keys in German, 10 otherwise) fills the width.
        let columns = CGFloat(rows[0].count)
        let unit = (inner - (columns - 1) * m.gap) / columns
        let wideKey = inner * 0.117      // shift and delete: 48.7 pt at 430 pt
        let modeKey = inner * 0.24       // 123 and return: 100 pt at 430 pt

        var index = 0
        for (r, row) in rows.enumerated() {
            let y = m.top + CGFloat(r) * (m.keyHeight + m.rowGap)
            var frames: [CGRect] = []
            if r < 2 {
                // Centred row of equal keys (the English middle row has one key fewer).
                let width = CGFloat(row.count) * unit + CGFloat(row.count - 1) * m.gap
                var x = (bounds.width - width) / 2
                for _ in row { frames.append(CGRect(x: x, y: y, width: unit, height: m.keyHeight)); x += unit + m.gap }
            } else if r == 2 {
                // Shift/page key left, delete right, the rest centred in between.
                let middle = row.count - 2
                let middleKeyWidth = page == .letters ? unit : min(unit * 1.4, (inner - 2 * wideKey - CGFloat(middle + 1) * m.gap) / CGFloat(middle))
                let middleWidth = CGFloat(middle) * middleKeyWidth + CGFloat(middle - 1) * m.gap
                frames.append(CGRect(x: m.side, y: y, width: wideKey, height: m.keyHeight))
                var x = (bounds.width - middleWidth) / 2
                for _ in 0..<middle {
                    frames.append(CGRect(x: x, y: y, width: middleKeyWidth, height: m.keyHeight)); x += middleKeyWidth + m.gap
                }
                frames.append(CGRect(x: bounds.width - m.side - wideKey, y: y, width: wideKey, height: m.keyHeight))
            } else {
                // Bottom row: page key, (globe), space, return.
                let hasGlobe = row.contains(.globe)
                let globeWidth = hasGlobe ? modeKey * 0.5 : 0
                let space = inner - 2 * modeKey - (hasGlobe ? globeWidth + m.gap : 0) - 2 * m.gap
                var x = m.side
                frames.append(CGRect(x: x, y: y, width: modeKey, height: m.keyHeight)); x += modeKey + m.gap
                if hasGlobe {
                    globeButton.frame = CGRect(x: x, y: y, width: globeWidth, height: m.keyHeight); x += globeWidth + m.gap
                }
                frames.append(CGRect(x: x, y: y, width: space, height: m.keyHeight)); x += space + m.gap
                frames.append(CGRect(x: x, y: y, width: modeKey, height: m.keyHeight))
                globeButton.isHidden = !hasGlobe
            }
            for frame in frames { keys[index].frame = frame; index += 1 }
        }
        for key in keys { key.fontSize = (m.letterFont, m.labelFont) }
    }

    // MARK: Labels and shift

    private var showsUppercase: Bool { page == .letters && shift != .off }

    private func updateLabels() {
        for key in keys { key.update(uppercase: showsUppercase, shift: shift, returnTitle: returnTitle) }
    }

    private var returnTitle: (text: String?, prominent: Bool) {
        let (title, prominent): (LocalizedStringResource?, Bool) =
            switch controller?.textDocumentProxy.returnKeyType ?? .default {
            case .go: (.returnGo, true)
            case .google, .yahoo, .search: (.returnSearch, true)
            case .join: (.returnJoin, true)
            case .next: (.returnNext, false)
            case .route: (.returnRoute, true)
            case .send: (.returnSend, true)
            case .done: (.returnDone, true)
            case .emergencyCall: (.returnEmergencyCall, true)
            case .continue: (.returnContinue, true)
            default: (nil, false)
            }
        return (title.map { String(localized: $0) }, prominent)
    }

    private func updateReturnKey() {
        keys.first { $0.kind == .returnKey }?.update(uppercase: showsUppercase, shift: shift, returnTitle: returnTitle)
    }

    private func setShift(_ new: Shift) {
        guard new != shift else { return }
        shift = new
        updateLabels()
    }

    private func setPage(_ new: Page) {
        guard new != page else { return }
        page = new
        if new == .letters { shift = .off }
        rebuildKeys()
        if new == .letters { updateAutoShift() }
    }

    /// Capitalizes like the system keyboard: at the start, after a sentence end, or per word,
    /// depending on what the text field asks for.
    func updateAutoShift() {
        guard page == .letters, shift != .locked, let proxy = controller?.textDocumentProxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let wantsUpper: Bool
        switch proxy.autocapitalizationType ?? .sentences {
        case .none: wantsUpper = false
        case .allCharacters: wantsUpper = true
        case .words: wantsUpper = before.isEmpty || before.last!.isWhitespace
        default:
            if before.isEmpty || before.last == "\n" {
                wantsUpper = true
            } else if before.last == " " {
                let trimmed = before.trimmingCharacters(in: .whitespaces)
                wantsUpper = trimmed.isEmpty || trimmed.last.map { ".!?\n".contains($0) } == true
            } else {
                wantsUpper = false
            }
        }
        setShift(wantsUpper ? .once : .off)
    }

    // MARK: Text actions

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    private var lastSpace = Date.distantPast

    /// The keyboard's feedback when a key goes down: the click sound (if switched on in Settings)
    /// and a light haptic tap, like the system keyboard with "Keyboard Feedback → Haptic".
    /// Third-party keyboards cannot read that setting, so the haptic always plays. Haptics in a
    /// keyboard need Full Access, which iDiktat requires anyway.
    private func click(_ key: KeyView) {
        UIDevice.current.playInputClick()
        haptic(keyHaptic, at: key)
    }

    private lazy var keyHaptic = UIImpactFeedbackGenerator(style: .light, view: self)
    /// A slightly stronger tap when a long press opens the accents or the cursor trackpad.
    private lazy var longPressHaptic = UIImpactFeedbackGenerator(style: .medium, view: self)

    /// Both taps play a little below their style's full strength, which felt slightly too strong
    /// on the iPhone. 1.0 is full strength.
    private let hapticIntensity: CGFloat = 0.8

    private func haptic(_ generator: UIImpactFeedbackGenerator, at key: KeyView) {
        generator.impactOccurred(intensity: hapticIntensity, at: key.center)
        // Keeps the Taptic Engine ready for the next key, so the tap comes without delay.
        generator.prepare()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { keyHaptic.prepare() }
    }

    private func type(_ text: String) {
        proxy?.insertText(text)
        lastSpace = .distantPast
        if shift == .once { setShift(.off) }
        // Like the system keyboard: an apostrophe on the number page returns to the letters.
        if page != .letters && text == "'" { setPage(.letters) }
        updateAutoShift()
    }

    private func typeSpace() {
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        // Double space: replace with ". " after a word, like the system keyboard.
        if Date().timeIntervalSince(lastSpace) < 0.6, before.hasSuffix(" "),
           let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            proxy.deleteBackward()
            proxy.insertText(". ")
            lastSpace = .distantPast
        } else {
            proxy.insertText(" ")
            lastSpace = Date()
        }
        if page != .letters { setPage(.letters) }
        updateAutoShift()
    }

    private func deleteBackward(word: Bool) {
        guard let proxy else { return }
        if word, let before = proxy.documentContextBeforeInput, !before.isEmpty {
            // Delete back to the start of the previous word (including trailing spaces).
            var count = 0
            var chars = Array(before)
            while let last = chars.last, last.isWhitespace { chars.removeLast(); count += 1 }
            while let last = chars.last, !last.isWhitespace { chars.removeLast(); count += 1 }
            for _ in 0..<max(count, 1) { proxy.deleteBackward() }
        } else {
            proxy.deleteBackward()
        }
        lastSpace = .distantPast
        updateAutoShift()
    }

    // MARK: Touches

    private enum Mode { case normal, accents([String]), trackpad }

    private final class Tracked {
        var key: KeyView
        var mode = Mode.normal
        var consumed = false
        var lastX: CGFloat
        var timer: Timer?
        init(key: KeyView, x: CGFloat) { self.key = key; lastX = x }
    }

    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var lastShiftTap = Date.distantPast
    private var deleteRepeats = 0

    /// The key under the point, counting the gaps around each key as part of it.
    private func key(at point: CGPoint) -> KeyView? {
        let m = metrics
        let hit = keys.first { $0.frame.insetBy(dx: -m.gap / 2 - 0.5, dy: -m.rowGap / 2 - 0.5).contains(point) }
        if let hit { return hit }
        // Outside every key (screen edge, above the top row): take the nearest one.
        return keys.min { distance($0.frame, point) < distance($1.frame, point) }
            .flatMap { distance($0.frame, point) < m.keyHeight ? $0 : nil }
    }

    private func distance(_ rect: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let key = key(at: point) else { continue }
            // A new finger commits a character still held by another finger (fast typing).
            for other in tracked.values where !other.consumed {
                if case .character = other.key.kind, case .normal = other.mode { commit(other) }
            }
            let state = Tracked(key: key, x: point.x)
            tracked[ObjectIdentifier(touch)] = state
            began(state)
        }
    }

    private func began(_ state: Tracked) {
        let key = state.key
        click(key)
        switch key.kind {
        case .character(let c):
            showPreview(for: key)
            if !metrics.showsPreview { key.isPressed = true }
            let variants = Accents.variants(for: c, language: language)
            if !variants.isEmpty {
                state.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak state] _ in
                    MainActor.assumeIsolated {
                        guard let self, let state, !state.consumed else { return }
                        let shown = self.showsUppercase ? variants.map { $0.uppercased() } : variants
                        state.mode = .accents(shown)
                        self.haptic(self.longPressHaptic, at: state.key)
                        self.popup.showAccents(shown, above: state.key.frame, in: self.bounds, font: self.metrics.letterFont)
                    }
                }
            }
        case .shift:
            key.isPressed = true
            let now = Date()
            switch shift {
            case .off: setShift(.once)
            case .once: setShift(now.timeIntervalSince(lastShiftTap) < 0.35 ? .locked : .off)
            case .locked: setShift(.off)
            }
            lastShiftTap = now
            state.consumed = true
        case .delete:
            key.isPressed = true
            deleteBackward(word: false)
            deleteRepeats = 0
            state.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak state] _ in
                MainActor.assumeIsolated { self?.startDeleteRepeat(state) }
            }
        case .space:
            key.isPressed = true
            state.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self, weak state] _ in
                MainActor.assumeIsolated {
                    guard let self, let state, !state.consumed else { return }
                    state.mode = .trackpad
                    self.haptic(self.longPressHaptic, at: state.key)
                    self.keys.forEach { $0.dimmed = true }
                }
            }
        case .returnKey, .page, .globe:
            key.isPressed = true
        }
    }

    private func startDeleteRepeat(_ state: Tracked?) {
        guard let state, !state.consumed else { return }
        state.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak state] timer in
            MainActor.assumeIsolated {
                guard let self, let state, !state.consumed else { return timer.invalidate() }
                self.deleteRepeats += 1
                // After about a second of holding, delete whole words, more slowly.
                let words = self.deleteRepeats > 10
                if words && self.deleteRepeats % 3 != 0 { return }
                self.click(state.key)
                self.deleteBackward(word: words)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked[ObjectIdentifier(touch)], !state.consumed else { continue }
            let point = touch.location(in: self)
            switch state.mode {
            case .accents:
                popup.selectAccent(atX: point.x)
            case .trackpad:
                // Move the cursor one character per 8 pt of finger travel.
                let steps = Int((point.x - state.lastX) / 8)
                if steps != 0 {
                    proxy?.adjustTextPosition(byCharacterOffset: steps)
                    state.lastX += CGFloat(steps) * 8
                }
            case .normal:
                // Sliding onto another character key moves the press there.
                guard case .character = state.key.kind, let other = key(at: point),
                      other !== state.key, case .character = other.kind else { continue }
                state.timer?.invalidate()
                state.key.isPressed = false
                state.key = other
                showPreview(for: other)
                if !metrics.showsPreview { other.isPressed = true }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            if !state.consumed { commit(state) }
            finish(state)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            state.consumed = true
            finish(state)
        }
    }

    /// Performs the key's action on release.
    private func commit(_ state: Tracked) {
        state.consumed = true
        state.timer?.invalidate()
        switch (state.key.kind, state.mode) {
        case (_, .accents):
            if let accent = popup.selectedAccent { type(accent) }
        case (.character(let c), _):
            type(showsUppercase ? c.uppercased() : c)
        case (.space, .trackpad):
            break
        case (.space, _):
            typeSpace()
        case (.returnKey, _):
            type("\n")
        case (.page(let target), _):
            setPage(target)
        default:
            break
        }
        if case .character = state.key.kind { popup.isHidden = true }
    }

    private func finish(_ state: Tracked) {
        state.timer?.invalidate()
        state.key.isPressed = false
        if case .trackpad = state.mode { keys.forEach { $0.dimmed = false } }
        if case .character = state.key.kind, !tracked.values.contains(where: { if case .character = $0.key.kind { return true } else { return false } }) {
            popup.isHidden = true
        }
    }

    private func showPreview(for key: KeyView) {
        guard metrics.showsPreview, case .character(let c) = key.kind else { return }
        popup.showPreview(showsUppercase ? c.uppercased() : c, above: key.frame, in: bounds, font: metrics.letterFont + 11)
    }
}

// MARK: - Accents

private enum Accents {
    static func variants(for c: String, language: TypingKeyboardView.Language) -> [String] {
        let german = language == .german
        switch c {
        case "a": return german ? ["à", "á", "â", "æ", "ã", "å", "ā"] : ["à", "á", "â", "ä", "æ", "ã", "å", "ā"]
        case "o": return german ? ["ô", "ò", "ó", "œ", "ø", "õ", "ō"] : ["ô", "ö", "ò", "ó", "œ", "ø", "õ", "ō"]
        case "u": return german ? ["û", "ù", "ú", "ū"] : ["û", "ü", "ù", "ú", "ū"]
        case "e": return ["é", "è", "ê", "ë", "ė", "ę", "ē"]
        case "i": return ["î", "ï", "í", "ī", "į", "ì"]
        case "s": return german ? ["ß", "ś", "š"] : ["ß", "ś", "š"]
        case "c": return ["ç", "ć", "č"]
        case "n": return ["ñ", "ń"]
        case "y": return ["ÿ"]
        case "z": return ["ž", "ź", "ż"]
        case "l": return ["ł"]
        case "-": return ["–", "—", "•"]
        case "\"": return ["„", "“", "”", "«", "»"]
        case "'": return ["‚", "‘", "’", "`"]
        case "?": return ["¿"]
        case "!": return ["¡"]
        case ".": return ["…"]
        case "€", "$": return ["€", "$", "£", "¥", "¢", "₩"].filter { $0 != c }
        case "&": return ["§"]
        case "0": return ["°"]
        default: return []
        }
    }
}

// MARK: - Key

final class KeyView: UIView {
    static let cornerRadius: CGFloat = 7.5
    /// Measured on the system keyboard: white keys in light mode, (70, 70, 70) in dark mode.
    static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 70 / 255, alpha: 1) : .white }
    static let pressedColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 42 / 255, alpha: 1) : UIColor(white: 0.80, alpha: 1) }

    let kind: TypingKeyboardView.Kind
    private let label = UILabel()
    private let icon = UIImageView()
    private var prominent = false
    var fontSize: (letter: CGFloat, label: CGFloat) = (22, 17.5) { didSet { applyFont() } }

    var isPressed = false { didSet { updateColors() } }
    /// While the space bar moves the cursor, the system keyboard blanks all labels.
    var dimmed = false { didSet { label.alpha = dimmed ? 0 : 1; icon.alpha = dimmed ? 0 : 1 } }

    init(kind: TypingKeyboardView.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.cornerRadius
        label.textAlignment = .center
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        icon.contentMode = .center
        icon.tintColor = .label
        addSubview(label)
        addSubview(icon)
        applyFont()
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The system keyboard sets its labels slightly above the middle of the key.
        label.frame = bounds.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: -1)
        icon.frame = bounds
    }

    private var isLetterKey: Bool { if case .character = kind { return true } else { return false } }

    private func applyFont() {
        label.font = isLetterKey ? .systemFont(ofSize: fontSize.letter) : .systemFont(ofSize: fontSize.label)
        let config = UIImage.SymbolConfiguration(pointSize: fontSize.label + 2, weight: .regular)
        icon.preferredSymbolConfiguration = config
    }

    func update(uppercase: Bool, shift: TypingKeyboardView.Shift, returnTitle: (text: String?, prominent: Bool)) {
        label.text = nil
        icon.image = nil
        prominent = false
        switch kind {
        case .character(let c):
            label.text = uppercase ? c.uppercased() : c
        case .shift:
            let name = switch shift { case .off: "shift"; case .once: "shift.fill"; case .locked: "capslock.fill" }
            icon.image = UIImage(systemName: name)
        case .delete:
            icon.image = UIImage(systemName: "delete.left")
        case .space:
            break
        case .returnKey:
            if let text = returnTitle.text { label.text = text } else { icon.image = UIImage(systemName: "return.left") }
            prominent = returnTitle.prominent
        case .page(let page):
            label.text = switch page { case .letters: "ABC"; case .numbers: "123"; case .symbols: "#+=" }
        case .globe:
            icon.image = UIImage(systemName: "globe")
        }
        updateColors()
    }

    private func updateColors() {
        if prominent {
            backgroundColor = isPressed ? .systemBlue.withAlphaComponent(0.7) : .systemBlue
            label.textColor = .white
        } else {
            backgroundColor = isPressed ? Self.pressedColor : Self.keyColor
            label.textColor = .label
        }
    }
}

// MARK: - Popup (key preview and accents)

/// The balloon above a pressed key, also used for the accent choice on long press.
final class KeyPopupView: UIView {
    private let shape = CAShapeLayer()
    private var labels: [UILabel] = []
    private let selection = UIView()
    private var accents: [String] = []
    private var cellFrames: [CGRect] = []
    private(set) var selectedIndex = 0

    var selectedAccent: String? { accents.indices.contains(selectedIndex) ? accents[selectedIndex] : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        selection.backgroundColor = .systemBlue
        selection.layer.cornerRadius = 6
        addSubview(selection)
        // A CALayer colour does not follow light/dark mode by itself.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyPopupView, _) in
            self.shape.fillColor = KeyView.keyColor.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showPreview(_ text: String, above key: CGRect, in bounds: CGRect, font: CGFloat) {
        accents = []
        let bubble = bubbleRect(width: key.width + 22, above: key, in: bounds)
        layout(bubble: bubble, key: key, texts: [text], font: font)
        selection.isHidden = true
    }

    func showAccents(_ texts: [String], above key: CGRect, in bounds: CGRect, font: CGFloat) {
        accents = texts
        selectedIndex = 0
        let cell = key.width + 4
        var bubble = bubbleRect(width: cell * CGFloat(texts.count) + 8, above: key, in: bounds)
        // Start at the key and grow to the right; flip left near the right edge.
        bubble.origin.x = min(max(key.minX - 4, bounds.minX + 2), bounds.maxX - 2 - bubble.width)
        layout(bubble: bubble, key: key, texts: texts, font: font)
        selection.isHidden = false
        // Start on the accent above the finger (the first one unless the bubble opened leftwards).
        selectedIndex = -1
        selectAccent(atX: key.midX)
    }

    func selectAccent(atX x: CGFloat) {
        guard !cellFrames.isEmpty else { return }
        let local = x - frame.minX
        let index = cellFrames.firstIndex { local < $0.maxX } ?? cellFrames.count - 1
        if index != selectedIndex { selectedIndex = index; updateSelection() }
    }

    private func updateSelection() {
        guard cellFrames.indices.contains(selectedIndex) else { return }
        selection.frame = cellFrames[selectedIndex].insetBy(dx: 1, dy: 4)
        for (i, label) in labels.enumerated() { label.textColor = i == selectedIndex ? .white : .label }
    }

    /// One outline from the bubble down to the key, with soft shoulders like the iOS balloon.
    private static func balloonPath(bubble b: CGRect, key k: CGRect) -> UIBezierPath {
        let r: CGFloat = 10
        let kr = KeyView.cornerRadius
        let shoulder = min(10, k.height / 3)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addArc(withCenter: CGPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addArc(withCenter: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
        if b.maxX - k.maxX > 2 * r {
            // Bubble reaches far past the key (accents): flat bottom edge, rounded into the key.
            p.addArc(withCenter: CGPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: k.maxX + r, y: b.maxY))
            p.addQuadCurve(to: CGPoint(x: k.maxX, y: b.maxY + r), controlPoint: CGPoint(x: k.maxX, y: b.maxY))
        } else {
            p.addCurve(to: CGPoint(x: k.maxX, y: k.minY + shoulder),
                       controlPoint1: CGPoint(x: b.maxX, y: b.maxY),
                       controlPoint2: CGPoint(x: k.maxX, y: k.minY))
        }
        p.addLine(to: CGPoint(x: k.maxX, y: k.maxY - kr))
        p.addArc(withCenter: CGPoint(x: k.maxX - kr, y: k.maxY - kr), radius: kr, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: k.minX + kr, y: k.maxY))
        p.addArc(withCenter: CGPoint(x: k.minX + kr, y: k.maxY - kr), radius: kr, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        if k.minX - b.minX > 2 * r {
            p.addLine(to: CGPoint(x: k.minX, y: b.maxY + r))
            p.addQuadCurve(to: CGPoint(x: k.minX - r, y: b.maxY), controlPoint: CGPoint(x: k.minX, y: b.maxY))
            p.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
            p.addArc(withCenter: CGPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        } else {
            p.addLine(to: CGPoint(x: k.minX, y: k.minY + shoulder))
            p.addCurve(to: CGPoint(x: b.minX, y: b.maxY - r),
                       controlPoint1: CGPoint(x: k.minX, y: k.minY),
                       controlPoint2: CGPoint(x: b.minX, y: b.maxY))
        }
        p.close()
        return p
    }

    private func bubbleRect(width: CGFloat, above key: CGRect, in bounds: CGRect) -> CGRect {
        let height = key.height * 1.08
        var rect = CGRect(x: key.midX - width / 2, y: key.minY - height - 2, width: width, height: height)
        rect.origin.x = min(max(rect.minX, bounds.minX + 2), bounds.maxX - 2 - rect.width)
        return rect
    }

    private func layout(bubble: CGRect, key: CGRect, texts: [String], font: CGFloat) {
        let union = bubble.union(key)
        frame = union
        let b = bubble.offsetBy(dx: -union.minX, dy: -union.minY)
        let k = key.offsetBy(dx: -union.minX, dy: -union.minY)
        shape.frame = bounds
        shape.path = Self.balloonPath(bubble: b, key: k).cgPath
        shape.fillColor = KeyView.keyColor.resolvedColor(with: traitCollection).cgColor

        labels.forEach { $0.removeFromSuperview() }
        let inset: CGFloat = texts.count > 1 ? 4 : 0
        let cellWidth = (b.width - 2 * inset) / CGFloat(texts.count)
        cellFrames = texts.indices.map { CGRect(x: b.minX + inset + CGFloat($0) * cellWidth, y: b.minY, width: cellWidth, height: b.height) }
        labels = texts.enumerated().map { i, text in
            let label = UILabel(frame: cellFrames[i])
            label.text = text
            label.textAlignment = .center
            label.font = .systemFont(ofSize: texts.count > 1 ? font - 2 : font, weight: .regular)
            label.textColor = .label
            addSubview(label)
            return label
        }
        isHidden = false
        superview?.bringSubviewToFront(self)
    }
}
