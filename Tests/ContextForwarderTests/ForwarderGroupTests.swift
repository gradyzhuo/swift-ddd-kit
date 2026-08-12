import Foundation
import Logging
import Testing
@testable import ContextForwarder

/// Covers `ForwarderGroup.runWithRestart`'s core contract: `body` returning
/// normally is NOT "done" (the server can close a subscription stream cleanly
/// on idle timeout / broker restart / LB reset), so BOTH a clean return and a
/// thrown error must back off and retry — and cancellation, including during
/// the backoff sleep, must exit promptly rather than waiting out the delay.
@Suite("ForwarderGroup restart loop")
struct ForwarderGroupTests {

    /// Call counter. An actor (not `@unchecked Sendable`) so concurrent
    /// access from the loop's repeated `body` invocations is race-free.
    private actor CallRecorder {
        private(set) var count = 0
        func increment() {
            count += 1
        }
    }

    @Test("a clean return backs off and retries, without hot-spinning")
    func cleanReturnRetries() async throws {
        let recorder = CallRecorder()
        let logger = Logger(label: "ForwarderGroupTests")

        let task = Task {
            await ForwarderGroup.runWithRestart(
                label: "clean-return", restartDelay: .milliseconds(50), logger: logger
            ) {
                await recorder.increment()
                // Returns normally — simulates the server closing the
                // subscription stream cleanly.
            }
        }

        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        await task.value

        let finalCount = await recorder.count
        // A clean return must NOT end the loop (proves both-exits-backoff);
        // over ~250ms with a 50ms delay it should run several times, but a
        // regression to no backoff at all would hot-spin into the thousands.
        #expect(finalCount >= 3)
        #expect(finalCount < 100)
    }

    @Test("a thrown error backs off and retries, without hot-spinning")
    func throwingRetries() async throws {
        struct Boom: Error {}

        let recorder = CallRecorder()
        let logger = Logger(label: "ForwarderGroupTests")

        let task = Task {
            await ForwarderGroup.runWithRestart(
                label: "throwing", restartDelay: .milliseconds(50), logger: logger
            ) {
                await recorder.increment()
                throw Boom()
            }
        }

        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        await task.value

        let finalCount = await recorder.count
        #expect(finalCount >= 3)
        #expect(finalCount < 100)
    }

    @Test("cancellation during the backoff sleep exits promptly")
    func cancellationDuringSleepExitsPromptly() async throws {
        let logger = Logger(label: "ForwarderGroupTests")
        let clock = ContinuousClock()

        let start = clock.now
        let task = Task {
            await ForwarderGroup.runWithRestart(
                label: "long-backoff", restartDelay: .seconds(30), logger: logger
            ) {
                // Clean return, then the loop would otherwise sleep 30s
                // before retrying.
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        let elapsed = clock.now - start

        // Well under the 30s backoff — proves cancellation is observed during
        // the sleep itself, not just between iterations.
        #expect(elapsed < .seconds(5))
    }
}
