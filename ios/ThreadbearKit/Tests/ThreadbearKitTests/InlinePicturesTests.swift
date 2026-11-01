import Foundation
import Testing
@testable import ThreadbearKit

/// docs/protocol.md, "Pictures in a message", on the phone.
struct InlinePicturesTests {
    let m = InlinePictures.markString

    @Test func photosGoInWhereTheCursorIsWithASpaceEitherSide() {
        let one = InlinePictures.inserting(1, in: "compare this with that", replacing: NSRange(location: 12, length: 0))
        #expect(one.text == "compare this \(m) with that")
        #expect(one.firstIndex == 0)
        #expect(one.cursor == 14)
        // Two more at the end: after the first photo, spaced.
        let more = InlinePictures.inserting(2, in: one.text, replacing: NSRange(location: (one.text as NSString).length, length: 0))
        #expect(more.text == "compare this \(m) with that \(m) \(m) ")
        #expect(more.firstIndex == 1)
        // In place of a selection, and clamped past the end.
        #expect(InlinePictures.inserting(1, in: "a bad word", replacing: NSRange(location: 2, length: 3)).text == "a \(m) word")
        #expect(InlinePictures.inserting(1, in: "", replacing: NSRange(location: 9, length: 4)).text == "\(m) ")
    }

    @Test func marksGoAsNumberedMarkersAndPhotosAloneAsNoWords() {
        #expect(InlinePictures.sentText("this \(m) like \(m)") == "this [Picture 1] like [Picture 2]")
        #expect(InlinePictures.sentText("\(m) \(m) ") == "")
        #expect(InlinePictures.sentText("plain") == "plain")
    }

    @Test func eachPhotoHasOneMark() {
        #expect(InlinePictures.normalized("look", count: 2) == "look \(m) \(m)")
        #expect(InlinePictures.normalized("a \(m) b \(m)", count: 1) == "a \(m) b ")
        #expect(InlinePictures.removingMark(0, from: "this \(m) that") == "this that")
    }

    /// A message's markers become chips, the first naming each number.
    @Test func aMessageSplitsIntoWordsAndChips() {
        #expect(InlinePictures.pieces("this [Picture 1] like [Picture 2], see [Picture 1] again") == [
            .words("this "), .picture(1), .words(" like "), .picture(2), .words(", see [Picture 1] again"),
        ])
        #expect(InlinePictures.pieces("[Picture 1]") == [.picture(1)])
        #expect(InlinePictures.unplaced("this [Picture 1] and [Picture 2]", count: 2) == 0)
        #expect(InlinePictures.unplaced("see [Picture 2]", count: 3) == 2)
        #expect(InlinePictures.pieces("no pictures [picture 1] [Picture 0]") == [.words("no pictures [picture 1] [Picture 0]")])
    }
}
