import Foundation

/// Streams one chat turn's events. The caller owns the task: cancelling it disconnects, and Hermes then
/// interrupts the turn, so only an explicit Stop should cancel.
public func chatEvents(for request: URLRequest, session: URLSession,
                       copy: Copy = Copy(name: "Kobe")) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    throw HermesClient.error(status: status, data: body, path: request.url?.path ?? "")
                }
                var parser = SSEParser()
                var line = Data()
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 0x0A else { continue }
                    for frame in parser.feed(String(decoding: line, as: UTF8.self)) {
                        if let event = ChatEvent.decode(event: frame.event, data: frame.data, copy: copy) { continuation.yield(event) }
                    }
                    line.removeAll(keepingCapacity: true)
                }
                continuation.finish()
            } catch let error as URLError {
                continuation.finish(throwing: HermesClient.map(error))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
