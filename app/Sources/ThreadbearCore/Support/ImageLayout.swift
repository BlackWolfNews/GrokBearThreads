import CoreGraphics
import Foundation

/// Lays images out in rows for the transcript: each scaled to fit a box,
/// wrapping onto a new row when the next one won't fit.
public enum ImageLayout {
    /// The box a generated image fits in (points): larger than a tool's
    /// screenshot, which the transcript keeps to 320 by 240, since the
    /// picture is what the turn was for. Still a box, so a 1254 px square
    /// from gpt-image-2 doesn't fill the window.
    public static let generatedMaxSide: CGFloat = 420

    public struct Result: Sendable, Equatable {
        /// Relative to the image area's top-left.
        public var frames: [CGRect]
        public var height: CGFloat
    }

    /// Frames for images of pixel `sizes`. Each image fits within
    /// `cellWidth` by `maxHeight` (never scaled up). Images that share a row
    /// are then brought to that row's shortest height, keeping their shapes,
    /// so their tops and bottoms line up: fitted one by one, a screenshot
    /// beside a wider chart ended about 20 pt lower and the text after the
    /// row started under a step. `alignRight` pushes each row to the right
    /// edge of `maxWidth` (a user message's attachments).
    public static func frames(sizes: [CGSize], maxWidth: CGFloat, maxHeight: CGFloat, cellWidth: CGFloat,
                              gap: CGFloat, alignRight: Bool, minSide: CGFloat = 24) -> Result {
        guard !sizes.isEmpty else { return Result(frames: [], height: 0) }
        let cellWidth = min(maxWidth, cellWidth)
        let fitted = sizes.map { size -> CGSize in
            let scale = min(1, maxHeight / max(1, size.height), cellWidth / max(1, size.width))
            return CGSize(width: max(minSide, floor(size.width * scale)), height: max(minSide, floor(size.height * scale)))
        }

        // Rows of indices, filled left to right.
        var rows: [[Int]] = []
        var x: CGFloat = 0
        for (index, size) in fitted.enumerated() {
            if rows.isEmpty || (x > 0 && x + size.width > maxWidth) {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += size.width + gap
        }

        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        for row in rows {
            // One height per row: the shortest fitted one. Scaling down only
            // narrows images, so the row still fits.
            let height = row.count > 1 ? row.map { fitted[$0].height }.min() ?? 0 : fitted[row[0]].height
            var x: CGFloat = 0
            for index in row {
                let size = fitted[index]
                let width = row.count > 1 && size.height > height
                    ? max(minSide, floor(size.width * height / size.height)) : size.width
                frames[index] = CGRect(x: x, y: y, width: width, height: height)
                x += width + gap
            }
            if alignRight, let last = row.last {
                let shift = maxWidth - frames[last].maxX
                for index in row { frames[index].origin.x += shift }
            }
            y += height + gap
        }
        return Result(frames: frames, height: y - gap)
    }
}
