import SwiftUI
import UIKit

/// A text box that also takes a pasted photo. SwiftUI's TextField only ever
/// pastes text, so this is UIKit's text view with Paste offered whenever the
/// pasteboard holds an image. Pasting from the edit menu or ⌘V is the user's
/// own act, so reading the pasteboard then doesn't bring up iOS's "Allow
/// Paste" prompt; checking `hasImages` beforehand doesn't either.
struct PastableTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var lines: ClosedRange<Int>
    /// Nil when photos can't be sent: Paste is then text only.
    var onPasteImages: (([Data]) -> Void)?

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // Line up with a TextField's text: no inset or padding of its own.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholderLabel.text = placeholder
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        view.onPasteImages = onPasteImages
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let font = view.font else { return nil }
        let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lowest = font.lineHeight * CGFloat(lines.lowerBound)
        let highest = font.lineHeight * CGFloat(lines.upperBound)
        // Grows with the text up to its last line, then scrolls, like
        // TextField(axis: .vertical) with a lineLimit.
        let scrolls = fit > highest + 1
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: ceil(min(max(fit, lowest), highest)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PastableTextField
        init(_ parent: PastableTextField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? PastingTextView)?.placeholderLabel.isHidden = !view.text.isEmpty
        }
    }
}

final class PastingTextView: UITextView {
    var onPasteImages: (([Data]) -> Void)?
    let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override var accessibilityLabel: String? {
        get { placeholderLabel.text }
        set {}
    }

    private var pastesImages: Bool { onPasteImages != nil && UIPasteboard.general.hasImages }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // A plain text view turns Paste off for an image, as it can't hold one.
        if action == #selector(paste(_:)), pastesImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard pastesImages, let onPasteImages else { return super.paste(sender) }
        // Each as the full-size original: PhotoPrep shrinks it as it does a picked one.
        let images = (UIPasteboard.general.images ?? []).compactMap { $0.jpegData(compressionQuality: 1) }
        if images.isEmpty { return super.paste(sender) }
        onPasteImages(images)
    }
}
