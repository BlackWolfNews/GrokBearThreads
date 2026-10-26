import AppKit

/// Fonts, colours and spacing for the transcript. Colours are dynamic so
/// cached attributed strings follow light and dark mode.
enum Theme {
    static let bodySize: CGFloat = 13.5
    static let codeSize: CGFloat = 12.5
    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let boldFont = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
    static let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: bodySize), toHaveTrait: .italicFontMask)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    static let codeBoldFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .semibold)
    static let smallFont = NSFont.systemFont(ofSize: 11.5)
    static let toolFont = NSFont.systemFont(ofSize: 12.5)

    /// Widest the reading column gets; wider windows centre it.
    static let maxContentWidth: CGFloat = 780
    static let sideInset: CGFloat = 28

    static let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
    }
    static let inlineCodeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.06)
    }
    static let bubbleBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
    }
    static let addedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.55, blue: 0.27, alpha: 0.28) : NSColor(srgbRed: 0.85, green: 0.97, blue: 0.87, alpha: 1)
    }
    static let removedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.7, green: 0.2, blue: 0.2, alpha: 0.28) : NSColor(srgbRed: 1, green: 0.9, blue: 0.9, alpha: 1)
    }
    static let hunkBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.3, green: 0.4, blue: 0.7, alpha: 0.22) : NSColor(srgbRed: 0.92, green: 0.94, blue: 1, alpha: 1)
    }
    static let errorBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.7, green: 0.2, blue: 0.2, alpha: 0.2) : NSColor(srgbRed: 1, green: 0.94, blue: 0.94, alpha: 1)
    }
    static let cardBorder = NSColor.separatorColor

    static func paragraph(lineHeight: CGFloat = 1.22, spacing: CGFloat = 8, before: CGFloat = 0, head: CGFloat = 0, first: CGFloat? = nil, tail: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.headIndent = head
        style.firstLineHeadIndent = first ?? head
        style.tailIndent = tail
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph()]
    }
}

extension NSAttributedString.Key {
    /// Fill a rounded box behind the whole run (code blocks, cards).
    static let tbBlockBackground = NSAttributedString.Key("tbBlockBackground")
    /// Fill each line fragment edge to edge (diff lines).
    static let tbLineBackground = NSAttributedString.Key("tbLineBackground")
    /// A small rounded fill behind just the run's glyphs (inline code).
    static let tbInlineBackground = NSAttributedString.Key("tbInlineBackground")
}
