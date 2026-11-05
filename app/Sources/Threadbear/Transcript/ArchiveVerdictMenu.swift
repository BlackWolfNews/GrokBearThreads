import AppKit
import ThreadbearCore

/// The done card's Archive menu: Worked, Didn't work, Not needed. Pressing
/// Archive opens it and only a pick archives, so every thread put away from
/// the card says how it went (`threads.update`'s `verdict`). Mike asked for
/// a forced choice over a plain button with an optional dropdown (5 Nov):
/// the point is that it was put away on purpose, which ⌘E and a swipe
/// don't claim. Under them, Okey-dokey archives with no verdict, for the
/// threads that are just done and don't fit any of the three (Mike, 5 Nov).
@MainActor
final class ArchiveVerdictMenu: NSObject {
    private let pick: (ArchiveVerdict?) -> Void

    private init(pick: @escaping (ArchiveVerdict?) -> Void) {
        self.pick = pick
    }

    /// Opens under the clicked button, right edges lined up, or at the
    /// pointer when there's no button to hang it from.
    static func show(pick: @escaping (ArchiveVerdict?) -> Void) {
        let target = ArchiveVerdictMenu(pick: pick)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for verdict in ArchiveVerdict.allCases {
            let item = NSMenuItem(title: verdict.label, symbol: verdict.symbol, action: #selector(choose(_:)), target: target)
            item.representedObject = verdict.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Okey-dokey", symbol: "archivebox", action: #selector(chooseNone), target: target))
        // popUp tracks until the menu closes, so `target` lives that long.
        if let anchor = TranscriptTextView.actionAnchor, let view = anchor.view {
            let y = view.isFlipped ? anchor.rect.maxY + 4 : anchor.rect.minY - 4
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.rect.maxX - menu.size.width, y: y), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        withExtendedLifetime(target) {}
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let verdict = ArchiveVerdict(rawValue: raw) else { return }
        pick(verdict)
    }

    @objc private func chooseNone() {
        pick(nil)
    }
}
