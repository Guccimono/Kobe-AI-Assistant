import Foundation

/// Splits a server-sent-events byte stream into (event, data) frames. Frames may arrive in any chunking;
/// comment lines (": keepalive") are ignored.
public struct SSEParser: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [(event: String, data: String)] {
        buffer += chunk.replacingOccurrences(of: "\r\n", with: "\n")
        var frames: [(event: String, data: String)] = []
        while let end = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<end.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            var event = "message"
            var data: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("event:") {
                    event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    var value = line.dropFirst(5)
                    if value.hasPrefix(" ") { value = value.dropFirst() }
                    data.append(String(value))
                }
            }
            if !data.isEmpty { frames.append((event, data.joined(separator: "\n"))) }
        }
        return frames
    }
}
