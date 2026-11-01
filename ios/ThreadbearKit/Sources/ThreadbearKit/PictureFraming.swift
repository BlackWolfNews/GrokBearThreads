import CoreGraphics

/// How a picture sits in the phone's full-screen viewer. `top`, `left`,
/// `bottom` and `right` are the room to keep clear of it: the notch, the Close
/// and Share buttons, the home indicator. So the whole picture shows when it
/// opens, whatever its shape, while a zoomed one can still use the whole screen
/// as you drag it about. Here rather than in the view so a test can hold it.
public struct PictureFraming: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// The picture's size when it opens: as big as fits in the clear part of
    /// the screen, which can be bigger than its own pixels.
    public func fitted(_ picture: CGSize, on screen: CGSize) -> CGSize {
        let clear = clearSize(on: screen)
        guard picture.width > 0, picture.height > 0, clear.width > 0, clear.height > 0 else { return clear }
        let fit = min(clear.width / picture.width, clear.height / picture.height)
        return CGSize(width: picture.width * fit, height: picture.height * fit)
    }

    /// The scroll view's insets for a picture at this size: centred in the
    /// clear part while it's smaller than that, and able to be dragged clear of
    /// the notch and buttons, so no edge of it ends up stuck under them.
    public func insets(showing picture: CGSize, on screen: CGSize) -> PictureFraming {
        let clear = clearSize(on: screen)
        let x = max(0, (clear.width - picture.width) / 2)
        let y = max(0, (clear.height - picture.height) / 2)
        return PictureFraming(top: top + y, left: left + x, bottom: bottom + y, right: right + x)
    }

    private func clearSize(on screen: CGSize) -> CGSize {
        CGSize(width: max(0, screen.width - left - right), height: max(0, screen.height - top - bottom))
    }
}
