import AppKit
import SwiftUI
import ThreadbareCore

/// A project's icon (docs/protocol.md, "Icons"): the picture the librarian
/// found in its folders, else its SF Symbol, else the title's first letter
/// in a quiet tile. `size` is in points before zoom.
struct ProjectIconView: View {
    let project: Project?
    /// The title to take a letter from when there's no project to hand
    /// (a chip from a summary the list hasn't caught up with).
    var title: String = ""
    let size: CGFloat

    var body: some View {
        let side = zoomed(size)
        Group {
            if let path = project?.icon?.image?.path, let image = ProjectIconImages.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            } else if let symbol = project?.icon?.symbol, ProjectIconImages.symbolExists(symbol) {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.78, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                Text(letter)
                    .font(.system(size: side * 0.62, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private var letter: String {
        let name = project?.title ?? title
        return name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "·"
    }
}

/// Pictures read once per path. Each copy the runner makes has its own
/// name (the file's hash is in it), so a changed icon is a new path and
/// nothing here goes stale.
@MainActor
enum ProjectIconImages {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var symbols: [String: Bool] = [:]

    static func image(at path: String) -> NSImage? {
        if let image = images[path] { return image }
        if missing.contains(path) { return nil }
        guard let image = NSImage(contentsOfFile: path), image.isValid else {
            missing.insert(path)
            return nil
        }
        images[path] = image
        return image
    }

    /// A symbol from a newer macOS (or a typo an agent made) draws nothing,
    /// so check first.
    static func symbolExists(_ name: String) -> Bool {
        if let known = symbols[name] { return known }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbols[name] = exists
        return exists
    }
}
