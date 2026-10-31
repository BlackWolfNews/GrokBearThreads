import Foundation

/// A card's icon and colour, from the name its agent chose
/// (POCKET_ICONS in runner/src/pocket-icons.ts). The colour goes with the
/// icon, so the same kind of card always looks the same.
public struct PocketIcon: Sendable, Hashable {
    public var symbol: String
    public var red: Double
    public var green: Double
    public var blue: Double

    private init(_ symbol: String, _ red: Int, _ green: Int, _ blue: Int) {
        self.symbol = symbol
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }

    /// No icon, or one this version doesn't know: a card from an older agent
    /// or a newer runner still looks like a card.
    public static let plain = PocketIcon("wallet.pass", 150, 160, 190)

    private static let named: [String: PocketIcon] = [
        "plane": PocketIcon("airplane", 127, 178, 240),
        "parcel": PocketIcon("shippingbox", 217, 143, 176),
        "shopping": PocketIcon("bag", 124, 196, 160),
        "tools": PocketIcon("hammer", 224, 164, 88),
        "food": PocketIcon("fork.knife", 232, 134, 100),
        "car": PocketIcon("car", 96, 190, 200),
        "health": PocketIcon("cross.case", 226, 110, 120),
        "ticket": PocketIcon("ticket", 170, 140, 232),
        "money": PocketIcon("creditcard", 214, 196, 96),
        "home": PocketIcon("house", 160, 190, 120),
    ]

    public static func named(_ name: String?) -> PocketIcon {
        name.flatMap { named[$0] } ?? plain
    }

    public static var names: [String] { Array(named.keys) }
}

/// When a swipe takes a card out: far enough left, or flicked. Up and down
/// is the deck scrolling, so a drag has to be mostly sideways to count.
public enum PocketSwipe {
    public static let removeAt = 110.0
    public static let flickAt = 240.0

    public static func isSideways(width: Double, height: Double) -> Bool {
        abs(width) > abs(height) * 1.5
    }

    public static func removes(width: Double, predictedWidth: Double) -> Bool {
        width <= -removeAt || (width < 0 && predictedWidth <= -flickAt)
    }
}
