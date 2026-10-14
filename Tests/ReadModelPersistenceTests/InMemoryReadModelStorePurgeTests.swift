import Testing
import EventSourcing
import ReadModelPersistence

private struct Summary: ReadModel, Sendable { let id: String }

@Suite("InMemoryReadModelStore — purge")
struct InMemoryReadModelStorePurgeTests {
    @Test("Purging its own type empties the store")
    func purgesOwnType() async throws {
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "a"), revision: 1)
        try await store.purgeSnapshots(ofTypes: [Summary.readModelTypeName])
        #expect(try await store.fetch(byId: "a") == nil)
    }

    @Test("Purging another type leaves the store untouched")
    func ignoresOtherTypes() async throws {
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "a"), revision: 1)
        try await store.purgeSnapshots(ofTypes: ["SomethingElse"])
        #expect(try await store.fetch(byId: "a")?.revision == 1)
    }
}
