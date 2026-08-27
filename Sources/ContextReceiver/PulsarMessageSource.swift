/// The transport seam. `ContextReceiver` drives this and nothing else, so all
/// of its logic is testable without a broker or a socket.
public protocol PulsarMessageSource: Sendable {
    /// Frames as they arrive. Finishes on a clean close; throws on transport failure.
    func frames() -> AsyncThrowingStream<ConsumerFrame, any Error>
    func settle(messageId: String, as disposition: ReceiveDisposition) async throws
    /// Pull-mode flow control: asks the broker for `count` more messages.
    func grantPermits(_ count: Int) async throws
}
