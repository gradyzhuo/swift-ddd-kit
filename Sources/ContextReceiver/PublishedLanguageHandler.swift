/// Implemented by the downstream context: translate a Published Language
/// event into local domain intent. Throwing decides the disposition, so
/// hosts should adopt `TransientReceiveError` on retryable failures.
public protocol PublishedLanguageHandler: Sendable {
    func handle(_ record: ReceivedRecord) async throws
}
