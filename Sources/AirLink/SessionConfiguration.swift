import CoAPCore
import PhilipsCrypto

/// Everything that can be tuned about a session. The host and port are always supplied by
/// the caller (flag, environment variable or app setting); nothing is hard-coded.
public struct SessionConfiguration: Sendable {
    public var host: String
    /// The device's CoAP port. 5683 is the CoAP default and what Air+ devices use.
    public var port: UInt16

    public var connectTimeout: Duration = .seconds(3)
    public var syncTimeout: Duration = .seconds(4)
    public var statusTimeout: Duration = .seconds(8)
    public var controlTimeout: Duration = .seconds(6)

    /// CON (the default here) gets retransmission and acknowledgement. aioairctrl 0.3.1 sends
    /// every request as NON and relies on its own retries.
    ///
    /// TODO(verify-con-non): whether the device accepts CON (and ACKs it) has not been
    /// checked on hardware. If CON requests time out, try `.nonConfirmable` (`--non`).
    public var messageType: CoAPMessage.MessageType = .confirmable

    public var counterPolicy: CounterWidthPolicy = .default

    /// Tear down the UDP socket and open a new one (new source port) on every resync.
    /// Some firmware appears to wedge per source port; plausible but unproven, so it's a toggle.
    public var freshConnectionOnResync = true

    /// Allow writes whose value literals are not verified on hardware (gen1/gen2 maps).
    public var allowUnverifiedWrites = false

    public var transport = CoAPTransport.Configuration()

    public init(host: String, port: UInt16 = 5683) {
        self.host = host
        self.port = port
    }

    /// `host:port`, bracketing IPv6 literals.
    public var endpointDescription: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
