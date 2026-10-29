import Foundation

/// Splits a byte stream into lines (NDJSON here), a byte at a time, as `URLSession.AsyncBytes`
/// hands them over, so a line is used the moment its newline arrives.
nonisolated struct SSELineDecoder {
    private var buffer: [UInt8] = []

    /// One byte at a time, as `URLSession.AsyncBytes` hands them over. Returns a line when this
    /// byte ends one, without its \r\n.
    mutating func push(byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D { buffer.removeLast() }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Every line these bytes complete.
    mutating func push<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        bytes.compactMap { push(byte: $0) }
    }

    /// Whatever's left when the stream ends without a final newline.
    mutating func finish() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return nil }
        if buffer.last == 0x0D { buffer.removeLast() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
