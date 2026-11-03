import AppKit
import WebKit

// Clicks count even while Threadbear isn't the app in front (Mike, 4 Nov).
//
// macOS swallows the click that brings a window forward unless the view
// under the pointer says otherwise: AppKit asks that one view's
// `acceptsFirstMouse(for:)`. Buttons, labels and tables say yes by
// themselves; plain views, image views, text views and web views say no.
// So each of those a click can land on answers true (search for
// "FirstClick.swift"), and SwiftUI gets `.allowsWindowActivationEvents()`
// at the root of each hosting view: RootView in ThreadbearApp, the composer
// card's collapse button and the review window. FirstClickTests walks the
// transcript's rows for any view that says no.

/// The transcript's icons (Symbols.makeView): a press on a row's chevron
/// lands on the icon, not the row.
final class FirstClickImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panels' web view, so a dashboard's buttons work on the first click.
final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
