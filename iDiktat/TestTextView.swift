import SwiftUI
import UIKit

/// The test field of the app. Unlike a SwiftUI TextField it remembers its keyboard: once you
/// switch to iDiktat with the globe key, iOS shows iDiktat here again next time. That lets
/// "Check Now" open the iDiktat keyboard directly, so it can confirm Full Access.
struct TestTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String

    func makeUIView(context: Context) -> RememberingTextView {
        let view = RememberingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0

        let label = view.placeholderLabel
        label.text = placeholder
        label.font = view.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: view.frameLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.frameLayoutGuide.trailingAnchor),
        ])
        return view
    }

    func updateUIView(_ view: RememberingTextView, context: Context) {
        if view.text != text { view.text = text }
        view.placeholderLabel.isHidden = !text.isEmpty
        view.wantsFocus = isFocused
        if isFocused && !view.isFirstResponder {
            view.takeFocus()
        } else if !isFocused && view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RememberingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let placeholder = uiView.placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 22
        // At least three lines, like the field before.
        return CGSize(width: width, height: max(fitted.height, placeholder.height + 16, lineHeight * 3 + 16))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: TestTextView
        init(_ parent: TestTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? RememberingTextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class RememberingTextView: UITextView {
    let placeholderLabel = UILabel()
    /// Focus was requested. The Form creates its rows lazily, so the field may not be in a
    /// window yet when "Check Now" asks for it; it then takes focus once it is.
    var wantsFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus { takeFocus() }
    }

    /// Becomes first responder as soon as UIKit allows it. Right after a button tap in the
    /// Form (and while the row is still being created) iOS refuses, so retry a few times.
    func takeFocus(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.1)) { [weak self] in
            guard let self, self.wantsFocus, !self.isFirstResponder else { return }
            if self.window == nil || !self.becomeFirstResponder(), attempt < 10 {
                self.takeFocus(attempt: attempt + 1)
            }
        }
    }

    /// With an identifier set, iOS remembers and restores the keyboard last used in this field.
    override var textInputContextIdentifier: String? { "de.cafe-megabyte.iDiktat.test-field" }
}
