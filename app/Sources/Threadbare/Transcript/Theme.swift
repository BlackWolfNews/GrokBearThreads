import AppKit

/// Fonts, colours and spacing for the transcript. Colours are dynamic so
/// cached attributed strings follow light and dark mode.
enum Theme {
    static let bodySize: CGFloat = 14
    /// Fixed line heights, with the glyphs centred in them (see `lines`):
    /// about 1.5 times the text size, like the apps Mike compares this with.
    static let bodyLine: CGFloat = 21
    static let codeSize: CGFloat = 12.5
    static let codeLine: CGFloat = 18.5
    static let diffSize: CGFloat = 12
    static let diffLine: CGFloat = 18
    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let boldFont = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
    static let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: bodySize), toHaveTrait: .italicFontMask)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    static let codeBoldFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .semibold)
    static let diffFont = NSFont.monospacedSystemFont(ofSize: diffSize, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    /// Work lines: group summaries, tool and thinking rows.
    static let workFont = NSFont.systemFont(ofSize: 13)
    static let workLine: CGFloat = 18
    static let cardTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let statsFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    /// Widest the reading column gets; wider windows centre it.
    static let maxContentWidth: CGFloat = 780
    static let sideInset: CGFloat = 28

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// Faint fills for code blocks, tool output and cards.
    static let codeBackground = dynamic(dark: NSColor(white: 1, alpha: 0.045), light: NSColor(white: 0, alpha: 0.03))
    static let inlineCodeBackground = dynamic(dark: NSColor(white: 1, alpha: 0.085), light: NSColor(white: 0, alpha: 0.055))
    static let cardBackground = dynamic(dark: NSColor(white: 1, alpha: 0.035), light: NSColor(white: 0, alpha: 0.02))
    static let cardBorder = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.12))
    /// Behind a work line the pointer is over (it opens on a click).
    static let hoverFill = dynamic(dark: NSColor(white: 1, alpha: 0.05), light: NSColor(white: 0, alpha: 0.04))
    static let hairline = dynamic(dark: NSColor(white: 1, alpha: 0.1), light: NSColor(white: 0, alpha: 0.1))

    /// The user's bubble: a touch of the accent colour over a faint fill.
    static let bubbleBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let (base, baseAlpha, accentAlpha): (CGFloat, CGFloat, CGFloat) = dark ? (1, 0.06, 0.09) : (0, 0.035, 0.09)
        // `accent` at `accentAlpha` composited over `base` grey at `baseAlpha`.
        let alpha = accentAlpha + baseAlpha * (1 - accentAlpha)
        func mix(_ channel: CGFloat) -> CGFloat { (channel * accentAlpha + base * baseAlpha * (1 - accentAlpha)) / alpha }
        return NSColor(srgbRed: mix(accent.redComponent), green: mix(accent.greenComponent), blue: mix(accent.blueComponent), alpha: alpha)
    }

    /// Diff line tints: about 11%, so a diff isn't the loudest thing on screen.
    static let addedBackground = dynamic(dark: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.4, alpha: 0.12),
                                         light: NSColor(srgbRed: 0.1, green: 0.62, blue: 0.25, alpha: 0.1))
    static let removedBackground = dynamic(dark: NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 0.12),
                                           light: NSColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.09))
    static let addedText = dynamic(dark: NSColor(srgbRed: 0.42, green: 0.84, blue: 0.5, alpha: 1),
                                   light: NSColor(srgbRed: 0.1, green: 0.55, blue: 0.22, alpha: 1))
    static let removedText = dynamic(dark: NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1),
                                     light: NSColor(srgbRed: 0.8, green: 0.15, blue: 0.15, alpha: 1))
    static let errorBackground = dynamic(dark: NSColor(srgbRed: 0.7, green: 0.2, blue: 0.2, alpha: 0.18),
                                         light: NSColor(srgbRed: 1, green: 0.94, blue: 0.94, alpha: 1))

    static func paragraph(lineHeight: CGFloat = 1, spacing: CGFloat = 8, before: CGFloat = 0, head: CGFloat = 0, first: CGFloat? = nil, tail: CGFloat = 0) -> NSMutableParagraphStyle {
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

    /// A paragraph style with every line `height` tall, and the baseline
    /// offset that centres `font`'s glyphs in it. TextKit puts the extra
    /// height of a line height multiple above the glyphs, which made a
    /// one-line bubble's text sit low; a fixed height with an offset splits
    /// it above and below, like CSS line-height.
    static func lines(_ height: CGFloat, font: NSFont, spacing: CGFloat = 0, before: CGFloat = 0, head: CGFloat = 0, first: CGFloat? = nil, tail: CGFloat = 0) -> (style: NSMutableParagraphStyle, offset: CGFloat) {
        let style = paragraph(spacing: spacing, before: before, head: head, first: first, tail: tail)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return (style, baselineOffset(height, font: font))
    }

    static func baselineOffset(_ height: CGFloat, font: NSFont) -> CGFloat {
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, (height - natural) / 2).rounded(.down)
    }

    /// Body text attributes for plain (not markdown) text.
    static func text(_ font: NSFont = bodyFont, color: NSColor = .labelColor, line: CGFloat = bodyLine, spacing: CGFloat = 0, alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let (style, offset) = lines(line, font: font, spacing: spacing)
        style.alignment = alignment
        return [.font: font, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: offset]
    }

    static var bodyAttributes: [NSAttributedString.Key: Any] { text() }
}

extension NSAttributedString.Key {
    /// Fill a rounded box behind the whole run (code blocks, cards).
    static let tbBlockBackground = NSAttributedString.Key("tbBlockBackground")
    /// Fill each line fragment edge to edge (diff lines).
    static let tbLineBackground = NSAttributedString.Key("tbLineBackground")
    /// A small rounded fill behind just the run's glyphs (inline code).
    static let tbInlineBackground = NSAttributedString.Key("tbInlineBackground")
}
