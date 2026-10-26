import AppKit

/// Every text size in the window, in one place. One step up from the
/// system's 13 pt default: at 14 pt body text Threadbare read about 2 pt
/// smaller than Codex and Claude beside it. Theme, the sidebar, the header
/// and the composer all take their sizes from here, so a text size setting
/// later only has to change this.
enum TypeScale {
    // Transcript
    static let body: CGFloat = 15
    /// Fixed line heights, with the glyphs centred in them (see
    /// `Theme.lines`): about 1.5 times the text size, like the apps Mike
    /// compares this with.
    static let bodyLine: CGFloat = 23
    /// Work lines: group summaries, tool and thinking rows, the working line.
    static let work: CGFloat = 14
    static let workLine: CGFloat = 20
    /// One monospaced size and leading for code blocks, tool output and
    /// diffs: at 12.5 and 13 a file read in a tool and the code block under
    /// it visibly differed in size and line spacing.
    static let code: CGFloat = 13
    static let codeLine: CGFloat = 19.5
    /// Tool output and file contents in an expanded tool.
    static let output: CGFloat = code
    static let outputLine: CGFloat = codeLine
    static let diff: CGFloat = code
    static let diffLine: CGFloat = codeLine
    static let headings: (CGFloat, CGFloat, CGFloat) = (18, 16, 15)
    static let cardTitle: CGFloat = 14
    /// Card labels, notes and table headers.
    static let label: CGFloat = 13
    /// Folders after file names, "Show 12 more lines", line counts. Whole
    /// points throughout: half-point steps made neighbouring text almost,
    /// but not quite, the same size.
    static let detail: CGFloat = 12
    /// The turn footer and centred system notes.
    static let small: CGFloat = 11

    // Sidebar
    static let sidebarTitle: CGFloat = 14
    static let sidebarPreview: CGFloat = 13
    /// Times, statuses and account names on a row.
    static let sidebarMeta: CGFloat = 11
    /// "Needs you", "Running", "Inbox": semibold at the previews' size, so a
    /// heading isn't weaker than the rows it groups.
    static let sidebarHeading: CGFloat = 13
    static let sidebarButton: CGFloat = 14
    static let sidebarFooter: CGFloat = 13

    // Header and composer
    /// At 14 the title was smaller than the 15 pt text under it; Codex and
    /// Claude set theirs at about 15.
    static let header: CGFloat = 15
    static let composer: CGFloat = 15
    static let chip: CGFloat = 13
}

/// Fonts, colours and spacing for the transcript. Colours are dynamic so
/// cached attributed strings follow light and dark mode.
enum Theme {
    static let bodySize = TypeScale.body
    static let bodyLine = TypeScale.bodyLine
    static let codeSize = TypeScale.code
    static let codeLine = TypeScale.codeLine
    static let diffSize = TypeScale.diff
    static let diffLine = TypeScale.diffLine
    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let boldFont = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
    static let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: bodySize), toHaveTrait: .italicFontMask)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    static let codeBoldFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .semibold)
    static let diffFont = NSFont.monospacedSystemFont(ofSize: diffSize, weight: .regular)
    static let outputFont = NSFont.monospacedSystemFont(ofSize: TypeScale.output, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: TypeScale.small)
    static let labelFont = NSFont.systemFont(ofSize: TypeScale.label)
    static let detailFont = NSFont.systemFont(ofSize: TypeScale.detail)
    static let workFont = NSFont.systemFont(ofSize: TypeScale.work)
    static let workLine = TypeScale.workLine
    /// A one-line label's height for `workFont`, so work lines centre their
    /// text the same way whatever the scale.
    static let workLabelHeight = ceil(workFont.ascender - workFont.descender + workFont.leading)
    static let cardTitleFont = NSFont.systemFont(ofSize: TypeScale.cardTitle, weight: .semibold)
    /// "Edited 3 files": quieter than a card that asks something.
    static let changesTitleFont = NSFont.systemFont(ofSize: TypeScale.cardTitle, weight: .medium)
    static let statsFont = NSFont.monospacedDigitSystemFont(ofSize: TypeScale.detail, weight: .regular)

    /// One digit's advance in a monospaced font, for line number gutters.
    static func digitWidth(_ font: NSFont) -> CGFloat {
        ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 4) / 4
    }

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

    /// Text tiers that read the same in both looks. The system's tertiary
    /// label is about 1.8:1 on white (2.4:1 on the dark pane), so times,
    /// footers, folder names and line numbers were near invisible in light
    /// mode and dim in dark. These are about 3.3:1 in both, and still
    /// clearly quieter than secondary text. Disabled controls and the light
    /// placeholder keep the system colour.
    static let faintText = dynamic(dark: NSColor(white: 1, alpha: 0.36), light: NSColor(white: 0, alpha: 0.45))
    /// Work line icons and chevrons.
    static let faintIcon = dynamic(dark: .tertiaryLabelColor, light: NSColor(white: 0, alpha: 0.36))
    /// Work lines and tool output: secondary, a step darker in light mode,
    /// where thin grey glyphs on white read lighter than their colour.
    static let quietText = dynamic(dark: .secondaryLabelColor, light: NSColor(white: 0, alpha: 0.6))

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
    /// "Needs you" and "Failed" in the sidebar. System orange and red on
    /// the light sidebar measured about 2:1; these darker light-mode shades
    /// are about 4.5:1 and the same hue.
    static let needsYou = dynamic(dark: .systemOrange, light: NSColor(srgbRed: 0.70, green: 0.33, blue: 0, alpha: 1))
    static let failed = dynamic(dark: .systemRed, light: NSColor(srgbRed: 0.78, green: 0.13, blue: 0.13, alpha: 1))
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
    /// Clicking the run does something in its row ("Show 30 more lines"):
    /// the value is passed to the text view's `onAction`.
    static let tbAction = NSAttributedString.Key("tbAction")
}
