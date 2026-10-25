import Foundation
import Testing
import DDDCore
import EventStoreContract
@testable import LocalEventStore

private typealias Store = PersistentEventStore<ContractStream, ContractMetadata>

func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalEventStoreTests-\(UUID().uuidString)", isDirectory: true)
}

func dddErrorSync(_ body: () throws -> Void) -> DDDError? {
    do { try body(); return nil } catch let error as DDDError { return error } catch { return nil }
}

func dddError(_ body: () async throws -> Void) async -> DDDError? {
    do { try await body(); return nil } catch let error as DDDError { return error } catch { return nil }
}

@Suite("PersistentEventStore lifecycle")
struct PersistentEventStoreLifecycleTests {

    @Test("open creates the directory, including intermediate directories")
    func openCreatesDirectory() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("a/b/c", isDirectory: true)

        let store = try Store.open(directory: directory, eventMapper: ContractEventMapper())
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        await store.close()
    }

    @Test("a regular file or a non-file URL is an invalid location")
    func invalidLocation() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("plain-file")
        try Data("x".utf8).write(to: file)

        #expect(dddErrorSync { _ = try Store.open(directory: file, eventMapper: ContractEventMapper()) }?
            .storeUnavailableReason == .invalidLocation)
        #expect(dddErrorSync { _ = try Store.open(directory: URL(string: "https://example.com/store")!, eventMapper: ContractEventMapper()) }?
            .storeUnavailableReason == .invalidLocation)
    }

    @Test("a second open of the same directory fails until the first is closed")
    func secondOpenOfSameDirectoryFails() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try Store.open(directory: directory, eventMapper: ContractEventMapper())
        #expect(dddErrorSync { _ = try Store.open(directory: directory, eventMapper: ContractEventMapper()) }?
            .storeUnavailableReason == .occupied)
        await first.close()

        let second = try Store.open(directory: directory, eventMapper: ContractEventMapper())
        await second.close()
    }

    @Test("dropping the store releases the lock")
    func droppingTheStoreReleasesTheLock() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try Store.open(directory: directory, eventMapper: ContractEventMapper())
        }
        _ = try Store.open(directory: directory, eventMapper: ContractEventMapper())
    }

    @Test("close is idempotent")
    func closeIsIdempotent() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try Store.open(directory: directory, eventMapper: ContractEventMapper())
        await store.close()
        await store.close()
        _ = try Store.open(directory: directory, eventMapper: ContractEventMapper())
    }
}
