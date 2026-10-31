import XCTest
@testable import ThreadbearCore

/// docs/protocol.md, "Pictures in a message": a draft's pictures are marks
/// (U+FFFC) in its text, a message's are [Picture N] markers.
final class InlinePicturesTests: XCTestCase {
    let m = InlinePictures.markString
    let red = ImageRef(path: "/media/red.png", mediaType: "image/png")
    let blue = ImageRef(path: "/media/blue.png", mediaType: "image/png")
    let green = ImageRef(path: "/media/green.png", mediaType: "image/png")

    func testADraftsMarksBecomeNumberedMarkers() {
        XCTAssertEqual(InlinePictures.messageText("this \(m) next to this \(m) please"),
                       "this [Picture 1] next to this [Picture 2] please")
        // After an ask box's two pictures, the composer's are 3 and 4.
        XCTAssertEqual(InlinePictures.messageText("\(m) and \(m)", first: 3), "[Picture 3] and [Picture 4]")
        XCTAssertEqual(InlinePictures.messageText("no pictures"), "no pictures")
    }

    /// Pictures and nothing else go as they always did: no words at all.
    func testPicturesAloneSendNoWords() {
        XCTAssertEqual(InlinePictures.sentText("\(m) \(m)\n"), "")
        XCTAssertEqual(InlinePictures.sentText(""), "")
        XCTAssertEqual(InlinePictures.sentText("hi \(m)", first: 2), "hi [Picture 2]")
        // Shown (a dump, a copy), the chips are still there.
        XCTAssertEqual(InlinePictures.messageText("\(m) \(m)"), "[Picture 1] [Picture 2]")
    }

    func testNormalizingGivesEachPictureOneMark() {
        XCTAssertEqual(InlinePictures.normalized("look \(m)", imageCount: 1), "look \(m)")
        // A picture added from outside the composer goes at the end.
        XCTAssertEqual(InlinePictures.normalized("look", imageCount: 2), "look \(m) \(m)")
        XCTAssertEqual(InlinePictures.normalized("", imageCount: 1), m)
        XCTAssertEqual(InlinePictures.normalized("look\n", imageCount: 1), "look\n\(m)")
        // Words carried over without their pictures lose the marks.
        XCTAssertEqual(InlinePictures.normalized("a \(m) b \(m) c", imageCount: 1), "a \(m) b  c")
        XCTAssertEqual(InlinePictures.normalized("\(m)\(m)", imageCount: 0), "")
    }

    func testMarkersPlaceTheFirstNamingEachPicture() {
        let text = "[Picture 2] then [Picture 1], [Picture 2] again, [Picture 9] and [picture 1]"
        let found = InlinePictures.markers(in: text, imageCount: 2)
        XCTAssertEqual(found.map(\.index), [1, 0])
        XCTAssertEqual(found.map { (text as NSString).substring(with: $0.range) }, ["[Picture 2]", "[Picture 1]"])
        XCTAssertTrue(InlinePictures.markers(in: text, imageCount: 0).isEmpty)
    }

    /// Editing a message puts each picture's chip back where its marker was.
    func testAMessageGoesBackIntoTheComposerWithItsChips() {
        let back = InlinePictures.draft(text: "this [Picture 2] like [Picture 1]", images: [red, blue])
        XCTAssertEqual(back.text, "this \(m) like \(m)")
        XCTAssertEqual(back.images, [blue, red])
        XCTAssertEqual(InlinePictures.messageText(back.text), "this [Picture 1] like [Picture 2]")
    }

    /// A message from before markers (or the phone's) had its pictures
    /// before the words, so that's where their chips go.
    func testPicturesNoMarkerPlacedGoFirst() {
        let old = InlinePictures.draft(text: "what colour?", images: [red, blue])
        XCTAssertEqual(old.text, "\(m)\(m) what colour?")
        XCTAssertEqual(old.images, [red, blue])
        let mixed = InlinePictures.draft(text: "see [Picture 3]", images: [red, blue, green])
        XCTAssertEqual(mixed.text, "\(m)\(m) see \(m)")
        XCTAssertEqual(mixed.images, [red, blue, green])
        XCTAssertEqual(InlinePictures.draft(text: "", images: [red]).text, m)
        // A stray mark in a message's words isn't a picture.
        XCTAssertEqual(InlinePictures.draft(text: "odd \(m) [Picture 1]", images: [red]).text, "odd  \(m)")
    }

    func testRemovingAChipTakesOneSpaceWithIt() {
        XCTAssertEqual(InlinePictures.removingMark(1, from: "this \(m) that \(m) end"), "this \(m) that end")
        XCTAssertEqual(InlinePictures.removingMark(0, from: "this \(m)"), "this")
        XCTAssertEqual(InlinePictures.removingMark(0, from: "\(m)"), "")
        XCTAssertEqual(InlinePictures.removingMark(3, from: "\(m)"), "\(m)")
    }

    func testWordsLeaveThePicturesOut() {
        XCTAssertEqual(InlinePictures.words("run \(m)this daily"), "run this daily")
    }
}
