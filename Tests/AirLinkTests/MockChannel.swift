@testable import AirLink
import CoAPCore
import Foundation

/// An in-memory `DatagramChannel`: tests inject datagrams "from the device" and inspect what
/// the transport sent.
final class MockChannel: DatagramChannel, @unchecked Sendable {
    let events: AsyncStream<ChannelEvent>
    private let eventSink: AsyncStream<ChannelEvent>.Continuation
    private let lock = NSLock()
    private var sentDatagrams: [[UInt8]] = []

    init() {
        (events, eventSink) = AsyncStream.makeStream(of: ChannelEvent.self)
    }

    func send(_ datagram: [UInt8]) async throws(TransportError) {
        lock.withLock { sentDatagrams.append(datagram) }
    }

    func close() {
        eventSink.finish()
    }

    func inject(_ message: CoAPMessage) throws {
        try eventSink.yield(.datagram(message.encode()))
    }

    func inject(_ event: ChannelEvent) {
        eventSink.yield(event)
    }

    var sent: [CoAPMessage] {
        lock.withLock { sentDatagrams }.compactMap { try? CoAPMessage.decode($0) }
    }

    /// Waits until at least `count` datagrams have been sent (or the timeout passes) and
    /// returns everything sent so far.
    @discardableResult
    func waitForSent(count: Int, timeout: Duration = .seconds(2)) async throws -> [CoAPMessage] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while sent.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        return sent
    }
}
