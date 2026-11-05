import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThreadbearKit

/// Codex's review of Daybreak finding 8: every picture under the per-file
/// cap could still add up, GIFs played at their own size, and any number
/// downloaded at once.
@Suite struct PictureMemoryTests {
    /// A hundred big pictures never hold more than the budget, the least
    /// recently used going first.
    @Test func theBudgetHoldsAcrossAllPictures() {
        let cache = CostLRU<Int, Data>(limit: 100)
        for i in 0..<100 {
            cache.set(Data(count: 1), for: i, cost: 24)
            #expect(cache.totalCost <= 100)
        }
        #expect(cache.count == 4)
        #expect(cache.value(for: 99) != nil)
        #expect(cache.value(for: 0) == nil)
        // Using one keeps it over an older one: 96 is the oldest until it's looked at.
        _ = cache.value(for: 96)
        cache.set(Data(), for: 200, cost: 10)
        #expect(cache.value(for: 96) != nil)
        #expect(cache.value(for: 97) == nil)
        #expect(cache.totalCost <= 100)
        // One over the whole budget isn't kept, and pushes nothing out.
        let before = cache.count
        cache.set(Data(), for: 300, cost: 101)
        #expect(cache.value(for: 300) == nil)
        #expect(cache.count == before)
    }

    @Test func downloadsRunAFewAtATime() async throws {
        let limit = ConcurrencyLimit(3)
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var now = 0, most = 0
            func change(_ by: Int) { lock.withLock { now += by; most = max(most, now) } }
        }
        let count = Count()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await limit.run {
                        count.change(1)
                        try await Task.sleep(for: .milliseconds(20))
                        count.change(-1)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(count.most == 3)
        #expect(count.now == 0)
    }

    static func gif(width: Int, height: Int, frames: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            ctx.setFillColor(red: CGFloat(i % 2), green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Frames come out at the size shown, not the file's.
    @Test func framesAreDecodedDownsampled() throws {
        let source = try #require(try PictureSource.open(Self.gif(width: 800, height: 400, frames: 3)))
        let plan = try #require(AnimationPlan(source, maxSide: 200))
        #expect(plan.delays.count == 3)
        #expect(abs(plan.delays[0] - 0.05) < 0.001)
        #expect(plan.loopCount == 0)
        let frame = try #require(plan.frame(source, at: 2))
        #expect(frame.width == 200 && frame.height == 100)
    }

    /// Too many frames, or too many pixels across them, plays only the first.
    @Test func aHugeAnimationPlaysOnlyItsFirstFrame() throws {
        // The real limits, scaled down so the test GIFs stay small to make.
        let source = try #require(try PictureSource.open(Self.gif(width: 400, height: 400, frames: 10)))
        #expect(AnimationPlan(source, maxSide: 400, maxFrames: 9) == nil)
        #expect(AnimationPlan(source, maxSide: 400, maxFrames: 10) != nil)
        // 10 frames at 400 x 400 shown is 1.6 MP to decode a loop.
        #expect(AnimationPlan(source, maxSide: 400, maxTotalPixels: 1_000_000) == nil)
        // The same file shown at 200 x 200 is 0.4 MP: fine.
        #expect(AnimationPlan(source, maxSide: 200, maxTotalPixels: 1_000_000) != nil)
        #expect(AnimationPlan.maxFrames == 600)
        // A still picture has no plan.
        #expect(AnimationPlan(try #require(try PictureSource.open(Self.gif(width: 4, height: 4, frames: 1))), maxSide: 200) == nil)
    }
}
