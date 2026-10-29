import Foundation

/// Turns a byte stream into text without breaking a character that's split across two network
/// chunks (an emoji or a curly quote arriving half in one chunk and half in the next).
nonisolated struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    /// Adds bytes and returns all the text that's now complete.
    mutating func decode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        let end = completeLength()
        guard end > 0 else { return "" }
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeFirst(end)
        return text
    }

    /// One byte at a time, as `URLSession.AsyncBytes` hands them over. ASCII skips the buffer.
    mutating func decode(byte: UInt8) -> String? {
        if pending.isEmpty, byte < 0x80 { return String(UnicodeScalar(byte)) }
        let text = decode(CollectionOfOne(byte))
        return text.isEmpty ? nil : text
    }

    /// Whatever's left when the stream ends; a cut-off character becomes U+FFFD.
    mutating func finish() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    /// The length of `pending` up to the start of a trailing, incomplete character.
    private func completeLength() -> Int {
        var i = pending.count - 1
        var continuationBytes = 0
        while i >= 0, continuationBytes < 4 {
            let byte = pending[i]
            if byte & 0xC0 == 0x80 {
                continuationBytes += 1
                i -= 1
                continue
            }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return pending.count - i < needed ? i : pending.count
        }
        return pending.count
    }
}
