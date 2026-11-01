import SwiftUI
import ThreadbearKit
import UIKit

/// A picture's chip among the words, as on the Mac (docs/protocol.md,
/// "Pictures in a message"): a small rounded tag with the picture and
/// "Picture N", the marker the agent gets. In the composer it shows the
/// photo; in a message, the photo symbol, as the phone never gets a
/// message's pictures, only its words.
enum PhotoChip {
    /// Sizes from the font of the words around it, so it follows Dynamic Type.
    struct Metrics {
        let font: UIFont
        let labelFont: UIFont
        let height: CGFloat
        let icon: CGFloat
        let gap: CGFloat
        let trailing: CGFloat
        let radius: CGFloat

        init(font: UIFont) {
            self.font = font
            labelFont = .systemFont(ofSize: (font.pointSize * 0.87).rounded())
            height = labelFont.lineHeight.rounded(.up) + (font.pointSize * 0.27).rounded()
            icon = height - (font.pointSize * 0.4).rounded()
            gap = (height * 0.25).rounded()
            trailing = (height * 0.35).rounded()
            radius = (height * 0.28).rounded()
        }

        var inset: CGFloat { ((height - icon) / 2).rounded() }

        /// Where the chip's bottom sits under the baseline: centred on the
        /// capitals beside it.
        var baselineOffset: CGFloat { ((font.capHeight - height) / 2).rounded() }
    }

    static func label(_ number: Int) -> String { "Picture \(number)" }

    /// The chip drawn for `traits` (light or dark), with the photo or else
    /// the photo symbol.
    static func image(number: Int, thumbnail: UIImage?, metrics: Metrics, traits: UITraitCollection) -> UIImage {
        let dark = traits.userInterfaceStyle == .dark
        let secondary = UIColor.secondaryLabel.resolvedColor(with: traits)
        let label = NSAttributedString(string: Self.label(number), attributes: [.font: metrics.labelFont, .foregroundColor: secondary])
        let size = CGSize(width: (metrics.inset + metrics.icon + metrics.gap + label.size().width + metrics.trailing).rounded(.up), height: metrics.height)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let shape = UIBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerRadius: metrics.radius)
            UIColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.06).setFill()
            shape.fill()
            UIColor.separator.resolvedColor(with: traits).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            let icon = CGRect(x: metrics.inset, y: (size.height - metrics.icon) / 2, width: metrics.icon, height: metrics.icon)
            if let thumbnail {
                // Filled into the square from the photo's middle.
                UIBezierPath(roundedRect: icon, cornerRadius: max(2, (metrics.icon * 0.18).rounded())).addClip()
                let scale = max(icon.width / thumbnail.size.width, icon.height / thumbnail.size.height)
                let drawn = CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                thumbnail.draw(in: CGRect(x: icon.midX - drawn.width / 2, y: icon.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
                UIGraphicsGetCurrentContext()?.resetClip()
            } else if let symbol = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.icon * 0.78))?
                .withTintColor(secondary, renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(x: icon.midX - symbol.size.width / 2, y: icon.midY - symbol.size.height / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
            label.draw(at: CGPoint(x: icon.maxX + metrics.gap, y: ((size.height - label.size().height) / 2).rounded()))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// A message's words with its [Picture N] markers drawn as chips.
    static func text(_ message: String, font: UIFont, traits: UITraitCollection) -> Text {
        let pieces = InlinePictures.pieces(message)
        guard pieces.contains(where: { if case .picture = $0 { true } else { false } }) else { return Text(verbatim: message) }
        let metrics = Metrics(font: font)
        var out = Text(verbatim: "")
        for piece in pieces {
            switch piece {
            case .words(let words):
                out = Text("\(out)\(Text(verbatim: words))")
            case .picture(let number):
                let chip = Text(Image(uiImage: image(number: number, thumbnail: nil, metrics: metrics, traits: traits)))
                    .baselineOffset(metrics.baselineOffset)
                out = Text("\(out)\(chip)")
            }
        }
        return out.accessibilityLabel(InlinePictures.messageText(message))
    }
}

/// A photo in the composer's words, the attachment behind a U+FFFC mark:
/// it carries its photo, so the words and photos are read straight off
/// the text, the k-th chip the k-th photo.
// Not on the main actor, as the app's types are by default: TextKit's own
// initialisers it overrides aren't.
nonisolated final class PhotoChipAttachment: NSTextAttachment {
    let photoId: UUID
    /// Its place among the box's photos when it was drawn; the words are
    /// laid out again once that's no longer so.
    let number: Int

    @MainActor init(photo: PickedPhoto, number: Int, font: UIFont, traits: UITraitCollection) {
        photoId = photo.id
        self.number = number
        super.init(data: nil, ofType: nil)
        let metrics = PhotoChip.Metrics(font: font)
        let image = PhotoChip.image(number: number, thumbnail: photo.thumbnail, metrics: metrics, traits: traits)
        self.image = image
        bounds = CGRect(x: 0, y: metrics.baselineOffset, width: image.size.width, height: image.size.height)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}
