/// Outbound port. Implementations must be safe to retry (at-least-once):
/// publishing the same event twice is expected under redelivery.
public protocol PublishedLanguagePublisher: Sendable {
    func publish(_ event: PublishedLanguageEvent) async throws
}
