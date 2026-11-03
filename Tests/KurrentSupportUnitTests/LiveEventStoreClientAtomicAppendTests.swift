import Testing
import Foundation
import KurrentDB
import KurrentSupport

// `appendRecords` needs a server, and `KurrentError.ConsistencyViolation` has no public
// initializer, so these pin the live seam's identity and its violation mapping offline.
// The live suite (KurrentLiveContractTests) checks the same mapping against a real server.

private func batch(_ stream: String, _ expected: StreamRevision) -> StreamBatch {
    StreamBatch(stream: stream, category: "Order", expectedRevision: expected, events: [])
}

@Suite("LiveEventStoreClient — identity and appendAtomically violation mapping")
struct LiveEventStoreClientAtomicAppendTests {

    @Test("identity is the wrapped KurrentDBClient's: shared by seams over one client, different across clients")
    func identityIsTheWrappedClients() {
        let kurrent = KurrentDBClient(settings: .localhost())
        let other = KurrentDBClient(settings: .localhost())

        #expect(LiveEventStoreClient(client: kurrent).identity == ObjectIdentifier(kurrent))
        #expect(LiveEventStoreClient(client: kurrent).identity == LiveEventStoreClient(client: kurrent).identity)
        #expect(LiveEventStoreClient(client: kurrent).identity != LiveEventStoreClient(client: other).identity)
    }

    @Test("an empty violation list is not mapped, so the original error is rethrown")
    func emptyViolationListIsNotMapped() {
        let mapped = LiveEventStoreClient.mapConsistencyViolations([], in: [batch("Order-A", .noStream)])
        #expect(mapped == nil)
    }

    @Test("a violation on a stream no batch writes is not mapped")
    func violationOnUnknownStreamIsNotMapped() {
        let mapped = LiveEventStoreClient.mapConsistencyViolations(
            [(stream: "Order-A", actualState: 0), (stream: "Order-X", actualState: 2)],
            in: [batch("Order-A", .noStream), batch("Order-B", .noStream)]
        )
        #expect(mapped == nil)
    }

    @Test("a tombstoned stream (-6) wins over revision conflicts; the first such batch in batch order is reported")
    func tombstonedStreamWinsInBatchOrder() throws {
        let mapped = LiveEventStoreClient.mapConsistencyViolations(
            [(stream: "Order-B", actualState: 4), (stream: "Order-C", actualState: -6), (stream: "Order-A", actualState: -6)],
            in: [batch("Order-A", .noStream), batch("Order-B", .at(1)), batch("Order-C", .noStream)]
        )
        let error = try #require(mapped as? KurrentError)
        #expect(error == .resourceDeleted(resource: "Order-A"))
    }

    @Test("violations become conflicts carrying the batch's expected revision; a negative state means no current revision")
    func violationsBecomeConflicts() throws {
        let mapped = LiveEventStoreClient.mapConsistencyViolations(
            [
                (stream: "Order-A", actualState: -1),
                (stream: "Order-B", actualState: -5),
                (stream: "Order-C", actualState: 7),
                (stream: "Order-D", actualState: -2),
            ],
            in: [batch("Order-A", .at(3)), batch("Order-B", .at(2)), batch("Order-C", .noStream), batch("Order-D", .streamExists)]
        )
        let error = try #require(mapped as? EventStoreClientError)
        #expect(error == .consistencyViolations([
            StreamConflict(stream: "Order-A", expected: .at(3), current: nil),
            StreamConflict(stream: "Order-B", expected: .at(2), current: nil),
            StreamConflict(stream: "Order-C", expected: .noStream, current: 7),
            StreamConflict(stream: "Order-D", expected: .streamExists, current: nil),
        ]))
    }
}
