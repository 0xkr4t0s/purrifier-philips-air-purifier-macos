import Foundation
import Network
import os

/// Something that moves whole datagrams to and from one peer. `CoAPTransport` talks to this
/// rather than to Network.framework directly, so its retransmission and matching logic can be
/// tested with an in-memory channel.
public protocol DatagramChannel: Sendable {
    /// Incoming datagrams and channel failures, in arrival order.
    var events: AsyncStream<ChannelEvent> { get }
    func send(_ datagram: [UInt8]) async throws(TransportError)
    func close()
}

public enum ChannelEvent: Sendable {
    case datagram([UInt8])
    /// A soft error (e.g. ICMP port unreachable). The channel keeps running.
    case error(TransportError)
}

/// Creates the channel for a session. Tests and the app can substitute their own.
/// Should throw `TransportError`. (Untyped because typed-throws function types need macOS 15.)
public typealias ChannelFactory = @Sendable (_ host: String, _ port: UInt16, _ timeout: Duration) async throws
    -> any DatagramChannel

/// A connected UDP socket to one host and port, on `NWConnection`.
public final class UDPChannel: DatagramChannel {
    public let events: AsyncStream<ChannelEvent>
    private let continuation: AsyncStream<ChannelEvent>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.purrifier.udp")

    private init(connection: NWConnection) {
        self.connection = connection
        (events, continuation) = AsyncStream.makeStream(of: ChannelEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Opens a UDP "connection" and waits until Network.framework reports it ready.
    ///
    /// UDP has no handshake, so readiness only means a route exists. On macOS 15+ a denied
    /// Local Network permission shows up here as a stuck `.waiting` state.
    public static func connect(
        host: String,
        port: UInt16,
        timeout: Duration
    ) async throws(TransportError) -> UDPChannel {
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw .invalidEndpoint("port \(port) is out of range")
        }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .invalidEndpoint("empty host") }

        let parameters = NWParameters.udp
        let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: parameters)
        let channel = UDPChannel(connection: connection)
        do {
            try await channel.start(timeout: timeout)
        } catch let error as TransportError {
            connection.cancel()
            throw error
        } catch {
            connection.cancel()
            throw .unreachable(String(describing: error))
        }
        channel.receiveNext()
        return channel
    }

    private func start(timeout: Duration) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let lastWaitingError = OSAllocatedUnfairLock<String?>(initialState: nil)
        let continuation = continuation
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [connection, queue] in
                try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
                    @Sendable func resumeOnce(_ result: Result<Void, any Error>) {
                        let first = resumed.withLock { done in
                            defer { done = true }
                            return !done
                        }
                        if first {
                            ready.resume(with: result)
                        }
                    }
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            resumeOnce(.success(()))
                        case let .waiting(error):
                            lastWaitingError.withLock { $0 = String(describing: error) }
                        case let .failed(error):
                            resumeOnce(.failure(TransportError.unreachable(String(describing: error))))
                            continuation.yield(.error(.unreachable(String(describing: error))))
                            continuation.finish()
                        case .cancelled:
                            resumeOnce(.failure(TransportError.closed))
                            continuation.finish()
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                let detail = lastWaitingError.withLock { $0 } ?? "no route after \(timeout)"
                throw TransportError.unreachable(detail)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                continuation.yield(.datagram(Array(data)))
            }
            if let error {
                if case let .posix(code) = error, code == .ECONNREFUSED {
                    // ICMP port unreachable: nothing is listening on that port. Defensive:
                    // in testing on macOS 27 Network.framework never reported this for UDP,
                    // so a wrong port usually surfaces as a timeout instead.
                    continuation.yield(.error(.connectionRefused))
                } else if case let .posix(code) = error, code == .ECANCELED {
                    continuation.finish()
                    return
                } else {
                    continuation.yield(.error(.receiveFailed(String(describing: error))))
                }
                // Keep reading after soft errors, but don't spin on a dead connection.
                switch connection.state {
                case .cancelled, .failed: continuation.finish(); return
                default: break
                }
            }
            receiveNext()
        }
    }

    public func send(_ datagram: [UInt8]) async throws(TransportError) {
        let result: Result<Void, TransportError> = await withCheckedContinuation { done in
            connection.send(content: Data(datagram), completion: .contentProcessed { error in
                if let error {
                    if case let .posix(code) = error, code == .ECONNREFUSED {
                        done.resume(returning: .failure(.connectionRefused))
                    } else {
                        done.resume(returning: .failure(.sendFailed(String(describing: error))))
                    }
                } else {
                    done.resume(returning: .success(()))
                }
            })
        }
        try result.get()
    }

    public func close() {
        connection.cancel()
        continuation.finish()
    }
}
