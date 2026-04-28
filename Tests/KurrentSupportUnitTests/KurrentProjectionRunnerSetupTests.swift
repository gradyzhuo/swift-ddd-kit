import Testing
import KurrentDB
import KurrentSupport

@Suite("KurrentProjection.PersistentSubscriptionRunner — setup")
struct KurrentProjectionRunnerSetupTests {

    @Test("Can construct runner with default retry policy and logger")
    func constructWithDefaults() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        // Smoke check — runner exists and is Sendable.
        let _: any Sendable = runner
    }

    @Test("Can construct runner with explicit retry policy")
    func constructWithExplicitPolicy() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 3)
        )
        let _: any Sendable = runner
    }
}
