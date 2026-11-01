import CoreGraphics
import Testing
@testable import ThreadbearKit

/// The full-screen picture on an iPhone 15 Pro Max: Mike couldn't see the top
/// of a big picture, which sat under the Dynamic Island and the buttons.
struct PictureFramingTests {
    let screen = CGSize(width: 430, height: 932)
    let framing = PictureFraming(top: 111, bottom: 34)

    @Test func aTallPictureOpensWhollyBelowTheNotch() {
        let size = framing.fitted(CGSize(width: 800, height: 4000), on: screen)
        #expect(abs(size.height - (932 - 111 - 34)) < 0.001)
        #expect(abs(size.width - size.height / 5) < 0.001)
        // Its top edge starts where the clear part does.
        let insets = framing.insets(showing: size, on: screen)
        #expect(insets.top == 111)
        #expect(insets.bottom == 34)
        #expect(abs(insets.left - (430 - size.width) / 2) < 0.001)
    }

    @Test func aWidePictureFillsTheWidthCentredInTheClearPart() {
        let size = framing.fitted(CGSize(width: 1600, height: 900), on: screen)
        #expect(size.width == 430)
        let insets = framing.insets(showing: size, on: screen)
        #expect(insets.left == 0)
        // As much room above as below, once the margins are taken off.
        #expect(insets.top - framing.top == insets.bottom - framing.bottom)
        #expect(abs(insets.top + size.height + insets.bottom - 932) < 0.001)
    }

    @Test func aZoomedPictureCanStillBeDraggedClearOfTheNotch() {
        let insets = framing.insets(showing: CGSize(width: 2000, height: 4000), on: screen)
        #expect(insets == framing)
    }

    @Test func noPictureOrNoRoomDoesNotDivideByZero() {
        #expect(framing.fitted(.zero, on: screen) == CGSize(width: 430, height: 787))
        #expect(PictureFraming(top: 2000).fitted(CGSize(width: 10, height: 10), on: screen) == CGSize(width: 430, height: 0))
    }
}
