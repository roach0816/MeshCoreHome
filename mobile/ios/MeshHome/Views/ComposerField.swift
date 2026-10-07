import SwiftUI
import UIKit

/// The message box. It is a UIKit text view so that Return on a hardware keyboard can send:
/// SwiftUI's multi-line TextField keeps Return for itself. Key commands only come from hardware
/// keyboards, so the on-screen keyboard's Return still starts a new line, as does Shift-Return.
struct ComposerField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines = 5
    var onReturn: () -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let v = ComposerTextView()
        v.delegate = context.coordinator
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.accessibilityIdentifier = "composer"
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.onReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onReturn() }
        return v
    }

    func updateUIView(_ v: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            v.text = text
            v.textChanged()
        }
        v.placeholder = placeholder
        if focused, !v.isFirstResponder, v.window != nil {
            DispatchQueue.main.async { v.becomeFirstResponder() }
        } else if !focused, v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let line = ceil(v.font?.lineHeight ?? 22)
        let fit = ceil(v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let limit = line * CGFloat(maxLines)
        let scrolls = fit > limit
        if v.isScrollEnabled != scrolls { DispatchQueue.main.async { v.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(max(fit, line), limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            (v as? ComposerTextView)?.textChanged()
        }
        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class ComposerTextView: UITextView {
    var onReturn: (() -> Void)?
    private let placeholderLabel = UILabel()

    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderLabel.text = placeholder
            accessibilityLabel = placeholder
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: placeholderLabel.font.lineHeight.rounded(.up))
    }

    func textChanged() {
        placeholderLabel.isHidden = !text.isEmpty
        invalidateIntrinsicContentSize()
    }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(sendFromKeyboard), input: "\r", modifierFlags: [])
        send.wantsPriorityOverSystemBehavior = true  // ahead of the text view inserting a line
        return [send]
    }

    @objc private func sendFromKeyboard() {
        // While typing with an input method (e.g. Japanese), Return confirms the candidate.
        if markedTextRange != nil { unmarkText(); return }
        onReturn?()
    }
}
