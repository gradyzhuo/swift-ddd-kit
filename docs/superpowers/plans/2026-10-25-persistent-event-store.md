# PersistentEventStore (B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `LocalEventStore` target with `PersistentEventStore`: an `EventStore` backed by one directory, one JSON file per stream, that survives restarts and passes the shared `EventStore` contract.

**Architecture:** An actor holding a directory URL, an `EventTypeMapper` and a lock file descriptor. Every operation reads and decodes the stream's file synchronously inside the actor (no suspension points, no cache), checks it, and replaces the whole file with `Data.write(options: .atomic)`. One open instance per directory is enforced with `flock` on `<directory>/.lock`. Errors use the `DDDError` codes 503 `storeUnavailable` and 504 `storeCorrupted` that plan A reserved.

**Tech Stack:** Swift 6.1+, Foundation, swift-log, swift-testing, POSIX `open`/`flock`/`close` (Darwin and Glibc/Musl).

**Spec:** `docs/superpowers/specs/2026-10-23-persistent-event-store-design.md` (rev 4). It depends on spec A, implemented in PR #31 (merged into `main`).

**Worktree:** `<main checkout>/.claude/worktrees/persistent-event-store` (branch `feat/persistent-event-store`, based on `origin/main`). Task 0 creates it from whichever checkout you start in; from Task 1 on, run every command from that worktree.

## Global Constraints

- Follow the `EventStore` contract exactly as `KurrentStorageCoordinator` does: 0-based revisions; empty `append` returns `nil` before any other check (not even the closed check); `version: nil` requires no stream; mismatch throws `DDDError.commitConflict` unless the batch's ids match the stored events right after `version` (then return that segment's last revision); `purge` is permanent for any id; read of a missing or purged stream returns `nil`; `fetchEvents(byId:)` returns `nil` when no event maps; `fetchEvents(byId:afterRevision:)` returns `(events: [], latestRevision: revision)` when nothing after `revision` maps; events whose mapper returns `nil` or throws are skipped (logged), and `latestRevision` is the revision of the last mapped event.
- Only `ENOENT` (`CocoaError.fileReadNoSuchFile`) means "stream does not exist". Every other read or write failure is `storeUnavailable(reason: .io)` and nothing is written.
- Undecodable file, `formatVersion != 1`, or `stream` field different from the requested name → `storeCorrupted(stream:)`, nothing written. `purge` never decodes the existing file.
- File name: lowercase hex of the stream name's UTF-8 bytes + `.json`. More than 120 UTF-8 bytes → `storeUnavailable(reason: .streamNameTooLong)`.
- No cache, no journal, no fsync, no custom executor, no file-I/O injection points (spec §8 removed them).
- Locking uses Swift-native or POSIX primitives only. Never `NSLock`.
- Never run bare `swift test` (it needs a live KurrentDB). Every run is `--filter`ed.
- Code, comments and commit messages in English; commit style `feat(scope): …` / `test(scope): …`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1
  ```
- Never merge the PR or push to `main`.

## Review Focus

1. **Precedence inside `append`**: empty → `nil`; closed → `.closed`; name too long → `.streamNameTooLong`; read failure → `.io`; corrupted → `storeCorrupted`; purged → `streamPurged`; version mismatch → idempotent resend or `commitConflict`. The contract, `corruptedStream`, `streamNameTooLong` and `closedStoreRejectsOperations` pin each outcome, but not every ordering: no test checks that the empty and closed checks run before the name check and the file read, or that a read failure maps to `.io`. Check those against Task 4's `append` by hand.
2. **Corrupted files are never rewritten by read or append**: pinned by `corruptedStream` comparing bytes before and after.
3. **`purge` removes payload bytes from the stream file**: pinned by `purgeSurvivesReopenAndDropsPayload`.
4. **Lock semantics on both macOS and Linux**: second `open` in the same process fails with `.occupied`; `close` and deinit release it. Pinned by `secondOpenOfSameDirectoryFails` and `droppingTheStoreReleasesTheLock`.
5. **Linux `ENOENT` mapping**: `Data(contentsOf:)` on a missing file must surface as `CocoaError.fileReadNoSuchFile` on Linux Foundation too. Pinned by every "new stream" contract rule; plan C runs `LocalEventStoreTests` and `EventStoreContractTests` on Linux CI.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/DDDCore/Adapter/DDDError.swift` (modify) | `StoreUnavailableReason`, `storeUnavailable(reason:path:detail:)`, `storeCorrupted(stream:)`, accessors |
| `Sources/EventSourcing/EventStorageCoordinator/IdempotentRevision.swift` (create) | The contract's id de-duplication rule as one `package` function, moved out of `InMemoryEventStore` |
| `Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift` (modify) | Calls the shared rule instead of its private copy |
| `Sources/LocalEventStore/StreamFile.swift` (create) | On-disk JSON shape of one stream; file-name encoding |
| `Sources/LocalEventStore/LocalRecordedEvent.swift` (create) | `RecordedEventLike` view of one stored record for the mapper |
| `Sources/LocalEventStore/DirectoryLock.swift` (create) | `flock`-based single-opener lock (file-scope POSIX calls) |
| `Sources/LocalEventStore/PersistentEventStore.swift` (create) | The actor: `open`, `close`, `EventStore` conformance |
| `Sources/DDDKit/DDDKit.swift`, `Package.swift` (modify) | New target, test target, umbrella re-export |
| `Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift` (modify) | 503/504 factories |
| `Tests/LocalEventStoreTests/StreamFileTests.swift` (create) | File-name encoding |
| `Tests/LocalEventStoreTests/PersistentEventStoreLifecycleTests.swift` (create) | open / close / lock / location errors |
| `Tests/LocalEventStoreTests/PersistentEventStoreFileTests.swift` (create) | Reopen, purge on disk, corruption, names |
| `Tests/LocalEventStoreTests/SharedInstanceTests.swift` (create) | Repository and projector sharing one instance |
| `Tests/EventStoreContractTests/EventStoreContractTests.swift` (modify) | Contract run for `PersistentEventStore` |
| `CLAUDE.md` (modify) | Describe the new target |

---

### Task 0: Worktree and plan

**Files:** none in code.

Every block below finds the main checkout with `git rev-parse --git-common-dir`, so it works from the main checkout or from any of its worktrees. Shell state does not carry between commands, so each block computes it again.

- [ ] **Step 1: Create the worktree on top of `main` (plan A is merged)**

```bash
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
git -C "$MAIN" fetch origin main
git -C "$MAIN" worktree add --no-track "$MAIN/.claude/worktrees/persistent-event-store" -b feat/persistent-event-store origin/main
```

- [ ] **Step 2: Bring this plan in and commit it**

The plan is untracked in the main checkout; copy it from there into the new worktree.

```bash
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
cd "$MAIN/.claude/worktrees/persistent-event-store"
cp "$MAIN/docs/superpowers/plans/2026-10-25-persistent-event-store.md" docs/superpowers/plans/
git add docs/superpowers/plans/2026-10-25-persistent-event-store.md
git commit -m "docs(plans): PersistentEventStore implementation plan

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

- [ ] **Step 3: Baseline build**

```bash
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.claude/worktrees/persistent-event-store"
swift build --build-tests
```

Expected: `Build complete!`

---

### Task 1: `DDDError` 503 / 504 factories

**Files:**
- Modify: `Sources/DDDCore/Adapter/DDDError.swift` (append to the `// MARK: - EventStore errors` extension)
- Test: `Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift`

- [ ] **Step 1: Write the failing tests**

Add inside `struct DDDErrorStoreCodesTests`:

```swift
    @Test("storeUnavailable carries reason, path and detail")
    func storeUnavailablePayload() {
        let error = DDDError.storeUnavailable(reason: .occupied, path: "/tmp/store", detail: "EWOULDBLOCK")
        #expect(error.code == .storeUnavailable)
        #expect(error.storeUnavailableReason == .occupied)
        #expect(error.userInfos["path"] as? String == "/tmp/store")
        #expect(error.userInfos["detail"] as? String == "EWOULDBLOCK")
        #expect(DDDError.storeCorrupted(stream: "Order-1").storeUnavailableReason == nil)
    }

    @Test("storeCorrupted carries the stream name")
    func storeCorruptedPayload() {
        let error = DDDError.storeCorrupted(stream: "Order-1")
        #expect(error.code == .storeCorrupted)
        #expect(error.corruptedStream == "Order-1")
        #expect(DDDError.streamPurged(id: "o-1").corruptedStream == nil)
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter DDDErrorStoreCodesTests`
Expected: compile error, `type 'DDDError' has no member 'storeUnavailable'`.

- [ ] **Step 3: Implement**

Append inside the existing `extension DDDError { … }` under `// MARK: - EventStore errors`, after `streamPurged(id:)`:

```swift
    /// Why a store could not serve a request (`code == .storeUnavailable`).
    public enum StoreUnavailableReason: String, Sendable, Equatable {
        /// The location is not a file URL or points at a regular file.
        case invalidLocation
        /// The stream name is longer than the store can map to a file name.
        case streamNameTooLong
        /// Reading or writing failed. Nothing was written.
        case io
        /// Another open store instance holds the location.
        case occupied
        /// The store was closed.
        case closed
    }

    /// The store could not serve the request. Nothing was written.
    public static func storeUnavailable(reason: StoreUnavailableReason, path: String, detail: String? = nil) -> Self {
        let errorCode = DDDError.Code.storeUnavailable
        var message = "[\(errorCode)] \(reason.rawValue): \(path)"
        var userInfos: [String: Sendable] = ["reason": reason, "path": path]
        if let detail {
            message += " (\(detail))"
            userInfos["detail"] = detail
        }
        return .init(code: errorCode, message: message, userInfos: userInfos)
    }

    /// The reason when `code == .storeUnavailable`, otherwise `nil`.
    public var storeUnavailableReason: StoreUnavailableReason? {
        guard code == .storeUnavailable else { return nil }
        return userInfos["reason"] as? StoreUnavailableReason
    }

    /// The stored data of `stream` cannot be read. Only that stream is affected;
    /// `purge` clears it; the id stays unwritable afterwards.
    public static func storeCorrupted(stream: String) -> Self {
        let errorCode = DDDError.Code.storeCorrupted
        let message = "[\(errorCode)] The stored data of \(stream) cannot be read."
        return .init(code: errorCode, message: message, userInfos: ["stream": stream])
    }

    /// The stream name when `code == .storeCorrupted`, otherwise `nil`.
    public var corruptedStream: String? {
        guard code == .storeCorrupted else { return nil }
        return userInfos["stream"] as? String
    }
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test --filter DDDErrorStoreCodesTests`
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/DDDCore/Adapter/DDDError.swift Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift
git commit -m "feat(core): add storeUnavailable and storeCorrupted factories

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 2: `LocalEventStore` target, file format and file names

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LocalEventStore/StreamFile.swift`, `Sources/LocalEventStore/LocalRecordedEvent.swift`
- Test: `Tests/LocalEventStoreTests/StreamFileTests.swift`

- [ ] **Step 1: Add the targets**

In `Package.swift`, after the `EventStoreContractTests` test target add:

```swift
        .target(
            name: "LocalEventStore",
            dependencies: [
                "DDDCore",
                "EventSourcing",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(
            name: "LocalEventStoreTests",
            dependencies: [
                "LocalEventStore",
                "EventStoreContract",
                "EventSourcing",
                "DDDCore",
            ]),
```

- [ ] **Step 2: Write the failing test**

`Tests/LocalEventStoreTests/StreamFileTests.swift`:

```swift
import Foundation
import Testing
import DDDCore
@testable import LocalEventStore

@Suite("StreamFile")
struct StreamFileTests {

    private func hex(_ name: String) -> String {
        name.utf8.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    @Test("file name is the lowercase hex of the UTF-8 stream name")
    func fileNameIsLowercaseHex() throws {
        for name in ["Order-1", "Order-A", "Order-a", "訂單-42", "a/b\\c:d"] {
            #expect(try StreamFile.fileName(forStream: name) == hex(name) + ".json")
        }
        #expect(try StreamFile.fileName(forStream: "AZ") == "415a.json")
    }

    @Test("names longer than 120 UTF-8 bytes are rejected")
    func tooLongNamesAreRejected() throws {
        let longest = String(repeating: "x", count: 120)
        #expect(try StreamFile.fileName(forStream: longest).count == 240 + 5)

        do {
            _ = try StreamFile.fileName(forStream: longest + "x")
            Issue.record("expected streamNameTooLong")
        } catch let error as DDDError {
            #expect(error.storeUnavailableReason == .streamNameTooLong)
        }
    }

    @Test("records omit metadata when there is none")
    func encodingOmitsMissingMetadata() throws {
        let file = StreamFile(
            stream: "Order-1",
            records: [.init(eventId: UUID(), eventType: "OrderCreated", payload: Data("{}".utf8), metadata: nil)]
        )
        let json = String(decoding: try StreamFile.encode(file), as: UTF8.self)
        #expect(json.contains("\"formatVersion\":1"))
        #expect(json.contains("\"purged\":false"))
        #expect(!json.contains("\"metadata\""))
        #expect(try JSONDecoder().decode(StreamFile.self, from: StreamFile.encode(file)) == file)
    }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `swift test --filter StreamFileTests`
Expected: compile error, `cannot find 'StreamFile' in scope` (or the target has no sources yet).

- [ ] **Step 4: Implement**

`Sources/LocalEventStore/StreamFile.swift`:

```swift
//
//  StreamFile.swift
//  DDDKit
//

import DDDCore
import Foundation

/// The on-disk content of one stream: `<directory>/<StreamFile.fileName(forStream:)>`.
/// A record's revision is its index in `records`.
struct StreamFile: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    /// File names are 2 hex digits per byte plus `.json`; 120 bytes keeps them under
    /// the common 255-byte file-name limit.
    static let maxStreamNameBytes = 120

    struct Record: Codable, Equatable, Sendable {
        var eventId: UUID
        var eventType: String
        /// The event exactly as `JSONEncoder` produced it at append time.
        var payload: Data
        /// The batch's encoded metadata; omitted when the batch had none.
        var metadata: Data?
    }

    var formatVersion: Int
    var stream: String
    var purged: Bool
    var records: [Record]

    init(stream: String, purged: Bool = false, records: [Record] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.stream = stream
        self.purged = purged
        self.records = records
    }

    /// Lowercase hex of the stream name's UTF-8 bytes, so names that differ only in
    /// case never share a file on a case-insensitive file system.
    static func fileName(forStream stream: String) throws -> String {
        let bytes = Array(stream.utf8)
        guard bytes.count <= maxStreamNameBytes else {
            throw DDDError.storeUnavailable(
                reason: .streamNameTooLong, path: stream,
                detail: "\(bytes.count) UTF-8 bytes, at most \(maxStreamNameBytes)")
        }
        let digits = Array("0123456789abcdef")
        var name = ""
        name.reserveCapacity(bytes.count * 2 + 5)
        for byte in bytes {
            name.append(digits[Int(byte >> 4)])
            name.append(digits[Int(byte & 0x0f)])
        }
        return name + ".json"
    }

    static func encode(_ file: StreamFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }
}
```

`Sources/LocalEventStore/LocalRecordedEvent.swift`:

```swift
//
//  LocalRecordedEvent.swift
//  DDDKit
//

import EventSourcing
import Foundation

/// One stored record as the `EventTypeMapper` sees it.
struct LocalRecordedEvent: RecordedEventLike {
    let id: UUID
    let eventType: String
    let revision: UInt64
    let customMetadata: Data
    let streamName: String
    let payload: Data

    init(record: StreamFile.Record, revision: UInt64, streamName: String) {
        self.id = record.eventId
        self.eventType = record.eventType
        self.revision = revision
        self.customMetadata = record.metadata ?? Data()
        self.streamName = streamName
        self.payload = record.payload
    }

    func decode<T: Decodable>(to type: T.Type) throws -> T? {
        try JSONDecoder().decode(type, from: payload)
    }
}
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `swift test --filter StreamFileTests`
Expected: 3 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/LocalEventStore Tests/LocalEventStoreTests
git commit -m "feat(local-store): add the LocalEventStore target with the stream file format

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 3: `open`, `close` and the directory lock

**Files:**
- Create: `Sources/LocalEventStore/DirectoryLock.swift`, `Sources/LocalEventStore/PersistentEventStore.swift`
- Test: `Tests/LocalEventStoreTests/PersistentEventStoreLifecycleTests.swift`

The actor is created here without `EventStore` conformance; Task 4 adds it. POSIX `open`/`close` are called only from file scope in `DirectoryLock.swift`, because inside the actor those names resolve to its own `open(directory:eventMapper:)` / `close()`.

- [ ] **Step 1: Write the failing tests**

`Tests/LocalEventStoreTests/PersistentEventStoreLifecycleTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter PersistentEventStoreLifecycleTests`
Expected: compile error, `cannot find type 'PersistentEventStore' in scope`.

- [ ] **Step 3: Implement the lock**

`Sources/LocalEventStore/DirectoryLock.swift`:

```swift
//
//  DirectoryLock.swift
//  DDDKit
//

import DDDCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Takes an exclusive, non-blocking `flock` on `<directory>/.lock` and returns the
/// descriptor. `flock` belongs to the open file description, so a second call for
/// the same directory fails even inside the same process.
func acquireDirectoryLock(in directory: URL) throws -> Int32 {
    let lockURL = directory.appendingPathComponent(".lock")
    let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
    }
    guard descriptor >= 0 else {
        throw DDDError.storeUnavailable(reason: .io, path: lockURL.path, detail: "open failed, errno \(errno)")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        _ = close(descriptor)
        let reason: DDDError.StoreUnavailableReason = code == EWOULDBLOCK ? .occupied : .io
        throw DDDError.storeUnavailable(reason: reason, path: directory.path, detail: "flock failed, errno \(code)")
    }
    return descriptor
}

/// Closes the lock descriptor, which releases the `flock`.
func releaseDirectoryLock(_ descriptor: Int32) {
    _ = close(descriptor)
}
```

- [ ] **Step 4: Implement the actor shell**

`Sources/LocalEventStore/PersistentEventStore.swift`:

```swift
//
//  PersistentEventStore.swift
//  DDDKit
//

import DDDCore
import EventSourcing
import Foundation
import Logging

/// An `EventStore` backed by one directory: one JSON file per stream, replaced
/// atomically on every write, so a process crash leaves each file either old or new.
///
/// - One open instance per directory (`open` fails with `.occupied` otherwise).
///   Share that instance between the repository and the projectors that read it.
/// - Not durable across power loss or an OS crash: atomic writes are not fsynced,
///   so the latest writes can be lost and a just-replaced file can read back
///   corrupted (`storeCorrupted` for that stream only; `purge` clears it but
///   leaves the id unwritable).
/// - Keep the directory inside the app's own container (e.g. Application Support).
///   Shared containers, cloud-synced folders and network file systems are not
///   supported.
/// - Every append rewrites the whole stream file; meant for aggregate streams with
///   a bounded number of events.
public actor PersistentEventStore<StreamNaming: EventStreamNaming, Metadata: EventMetadata> {
    let directory: URL
    let eventMapper: any EventTypeMapper
    let logger = Logger(label: "PersistentEventStore")
    /// `nil` once closed.
    var lockDescriptor: Int32?

    private init(directory: URL, eventMapper: any EventTypeMapper, lockDescriptor: Int32) {
        self.directory = directory
        self.eventMapper = eventMapper
        self.lockDescriptor = lockDescriptor
    }

    deinit {
        if let lockDescriptor {
            releaseDirectoryLock(lockDescriptor)
        }
    }

    /// Opens (creating it if needed) the store in `directory`.
    ///
    /// - Throws: `DDDError.storeUnavailable` with `.invalidLocation` when `directory`
    ///   is not a file URL or is a regular file, `.occupied` when another instance has
    ///   it open, `.io` when it cannot be created or locked.
    public static func open(directory: URL, eventMapper: any EventTypeMapper) throws -> PersistentEventStore {
        guard directory.isFileURL else {
            throw DDDError.storeUnavailable(reason: .invalidLocation, path: directory.absoluteString)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw DDDError.storeUnavailable(reason: .invalidLocation, path: directory.path)
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw DDDError.storeUnavailable(reason: .io, path: directory.path, detail: "\(error)")
            }
        }
        let descriptor = try acquireDirectoryLock(in: directory)
        return PersistentEventStore(directory: directory, eventMapper: eventMapper, lockDescriptor: descriptor)
    }

    /// Releases the directory. Idempotent; every later operation throws
    /// `storeUnavailable(reason: .closed)`.
    public func close() {
        guard let descriptor = lockDescriptor else { return }
        lockDescriptor = nil
        releaseDirectoryLock(descriptor)
    }
}
```

- [ ] **Step 5: Run them and confirm they pass**

Run: `swift test --filter PersistentEventStoreLifecycleTests`
Expected: 5 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocalEventStore Tests/LocalEventStoreTests
git commit -m "feat(local-store): open and close PersistentEventStore with a directory lock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 4: `EventStore` conformance, proven by the contract

**Files:**
- Create: `Sources/EventSourcing/EventStorageCoordinator/IdempotentRevision.swift`
- Modify: `Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift`, `Sources/LocalEventStore/PersistentEventStore.swift`, `Package.swift` (`EventStoreContractTests` dependency), `Tests/EventStoreContractTests/EventStoreContractTests.swift`

- [ ] **Step 1: Add the contract run (red)**

In `Package.swift`, add `"LocalEventStore"` to the `EventStoreContractTests` dependencies.

In `Tests/EventStoreContractTests/EventStoreContractTests.swift` add `import Foundation` and `import LocalEventStore` to the imports, and inside the suite:

```swift
    @Test("PersistentEventStore")
    func persistentEventStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentEventStoreContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EventStoreContract.checkAll(serialized: true) {
            try PersistentEventStore<ContractStream, ContractMetadata>.open(
                directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                eventMapper: ContractEventMapper()
            )
        }
    }

    @Test("PersistentEventStore: huge versions conflict instead of trapping")
    func persistentEventStoreHugeVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentEventStoreContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EventStoreContract.checkHugeVersionConflicts {
            try PersistentEventStore<ContractStream, ContractMetadata>.open(
                directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                eventMapper: ContractEventMapper()
            )
        }
    }
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter EventStoreContractTests`
Expected: compile error, `type 'PersistentEventStore<ContractStream, ContractMetadata>' does not conform to protocol 'EventStore'` (or the generic constraint on `checkAll` is not satisfied).

- [ ] **Step 3: Implement**

First move `InMemoryEventStore`'s id de-duplication into one `package` function, so both stores share one copy of the rule. `package` access is visible to every module in this package; the repo already uses it (`AggregateRootMetadata`, `EventBus`).

`Sources/EventSourcing/EventStorageCoordinator/IdempotentRevision.swift`:

```swift
//
//  IdempotentRevision.swift
//  DDDKit
//

import Foundation

/// The contract's id de-duplication (KurrentDB's rule), shared by the stores in this
/// package: a batch whose ids equal the stored ids right after `expected` was already
/// written, so the append answers with that segment's last revision. `nil` when the
/// batch does not match.
package func idempotentRevision(of batch: [UUID], in stored: [UUID], expected: UInt64?) -> UInt64? {
    let start: Int
    if let expected {
        // Bail out in UInt64 before converting: `Int(expected) + 1` traps for
        // versions near UInt64.max, and such a version can never match anyway.
        guard expected < UInt64(stored.count) else { return nil }
        start = Int(expected) + 1
    } else {
        start = 0
    }
    let end = start + batch.count
    guard end <= stored.count else { return nil }
    guard Array(stored[start..<end]) == batch else { return nil }
    return UInt64(end - 1)
}
```

In `Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift`:
- replace `Self.idempotentRevision(of: events, in: entry.events, expected: version)` with `idempotentRevision(of: events.map({ $0.id }), in: entry.events.map({ $0.id }), expected: version)`;
- delete `private static func idempotentRevision(of:in:expected:)` together with its two-line doc comment.

Keep the closures parenthesized: inside a `guard`/`if` condition an unparenthesized trailing closure is parsed as the statement body, and `events.map(\.id)` on `[any DomainEvent]` inside a generic actor crashes the Swift 6.4 frontend (SILGen assertion `!componentTy->hasTypeParameter()`).

Then change the `PersistentEventStore` declaration line to `public actor PersistentEventStore<StreamNaming: EventStreamNaming, Metadata: EventMetadata>: EventStore {` and append inside the actor, after `close()`:

```swift
    // MARK: - EventStore

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        guard let file = try load(stream: stream), !file.purged else { return nil }
        let mapped = map(file.records[...], stream: stream)
        guard let latestRevision = mapped.last?.revision else { return nil }
        return (events: mapped.map(\.event), latestRevision: latestRevision)
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        guard let file = try load(stream: stream), !file.purged else { return nil }
        // Compare in UInt64 first: `Int(revision) + 1` traps for revisions near UInt64.max.
        let start = revision < UInt64(file.records.count) ? Int(revision) + 1 : file.records.count
        let mapped = map(file.records[start...], stream: stream)
        guard let latestRevision = mapped.last?.revision else {
            return (events: [], latestRevision: revision)
        }
        return (events: mapped.map(\.event), latestRevision: latestRevision)
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        var file = try load(stream: stream) ?? StreamFile(stream: stream)
        guard !file.purged else { throw DDDError.streamPurged(id: id) }

        let tail: UInt64? = file.records.isEmpty ? nil : UInt64(file.records.count - 1)
        guard tail == version else {
            if let replayed = idempotentRevision(of: events.map({ $0.id }), in: file.records.map(\.eventId), expected: version) {
                return replayed
            }
            throw DDDError.commitConflict(id: id, expected: version, actual: tail)
        }

        let encoder = JSONEncoder()
        let metadataBytes: Data? = try metadata.map { try encoder.encode($0) }
        let records = try events.map { event in
            StreamFile.Record(
                eventId: event.id,
                eventType: event.eventType,
                payload: try encoder.encode(event),
                metadata: metadataBytes
            )
        }
        file.records.append(contentsOf: records)
        try write(file)
        return UInt64(file.records.count - 1)
    }

    /// Makes the id permanently unwritable and drops its events from the stream
    /// file. Logical deletion only: earlier temporary files or freed disk blocks may
    /// still hold the bytes. Also the way to clear a corrupted stream.
    public func purge(byId id: String) async throws {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        try write(StreamFile(stream: stream, purged: true))
    }

    // MARK: - File access

    private func ensureOpen() throws {
        guard lockDescriptor != nil else {
            throw DDDError.storeUnavailable(reason: .closed, path: directory.path)
        }
    }

    private func fileURL(forStream stream: String) throws -> URL {
        directory.appendingPathComponent(try StreamFile.fileName(forStream: stream), isDirectory: false)
    }

    /// The decoded file, or `nil` when it does not exist.
    private func load(stream: String) throws -> StreamFile? {
        let url = try fileURL(forStream: stream)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw DDDError.storeUnavailable(reason: .io, path: url.path, detail: "\(error)")
        }
        let file: StreamFile
        do {
            file = try JSONDecoder().decode(StreamFile.self, from: data)
        } catch {
            throw DDDError.storeCorrupted(stream: stream)
        }
        guard file.formatVersion == StreamFile.currentFormatVersion, file.stream == stream else {
            throw DDDError.storeCorrupted(stream: stream)
        }
        return file
    }

    /// Replaces the stream's file atomically; on failure the old file stays.
    private func write(_ file: StreamFile) throws {
        let url = try fileURL(forStream: file.stream)
        let data = try StreamFile.encode(file)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DDDError.storeUnavailable(reason: .io, path: url.path, detail: "\(error)")
        }
    }

    /// Maps records through `eventMapper`, skipping those it returns `nil` for or
    /// throws on. Revisions are the records' indices in the stream.
    private func map(
        _ records: ArraySlice<StreamFile.Record>, stream: String
    ) -> [(event: any DomainEvent, revision: UInt64)] {
        var mapped: [(event: any DomainEvent, revision: UInt64)] = []
        for (index, record) in zip(records.indices, records) {
            let revision = UInt64(index)
            let recorded = LocalRecordedEvent(record: record, revision: revision, streamName: stream)
            do {
                if let event = try eventMapper.mapping(eventData: recorded) {
                    mapped.append((event: event, revision: revision))
                }
            } catch {
                logger.warning("skipped event \(record.eventId) at revision \(revision) of \(stream): \(error)")
            }
        }
        return mapped
    }
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test --filter EventStoreContractTests`
Expected: 6 tests passed (the 4 existing plus the 2 new ones; the `InMemoryEventStore` runs now go through the shared rule).

Run: `swift test --filter '(LocalEventStoreTests|EventSourcingTests|ReadModelPersistenceTests|DDDKitUnitTests)'`
Expected: all pass (the last three use `InMemoryEventStore`).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/EventSourcing Sources/LocalEventStore Tests/EventStoreContractTests
git commit -m "feat(local-store): PersistentEventStore follows the EventStore contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 5: On-disk behaviour

**Files:**
- Test: `Tests/LocalEventStoreTests/PersistentEventStoreFileTests.swift`

These tests pin spec §3–§6 behaviour the contract cannot see. If one fails, fix `PersistentEventStore.swift`, not the test, unless the test contradicts the spec; report which.

- [ ] **Step 1: Write the tests**

`Tests/LocalEventStoreTests/PersistentEventStoreFileTests.swift`:

```swift
import Foundation
import Testing
import DDDCore
import EventStoreContract
@testable import LocalEventStore

private typealias Store = PersistentEventStore<ContractStream, ContractMetadata>

private func open(_ directory: URL) throws -> Store {
    try Store.open(directory: directory, eventMapper: ContractEventMapper())
}

private func fileURL(_ directory: URL, id: String) throws -> URL {
    directory.appendingPathComponent(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: id)))
}

enum Corruption: String, CaseIterable, Sendable {
    case truncated, empty, futureFormat, wrongStream
}

@Suite("PersistentEventStore on disk")
struct PersistentEventStoreFileTests {

    @Test("events, revisions and metadata survive close and reopen")
    func eventsSurviveReopen() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let events = [ContractEvent(aggregateRootId: id, value: 1), ContractEvent(aggregateRootId: id, value: 2)]

        let first = try open(directory)
        let revision = try await first.append(events: events, byId: id, version: nil, metadata: ContractMetadata(tag: "m"))
        #expect(revision == 1)
        await first.close()

        let second = try open(directory)
        let fetched = try #require(try await second.fetchEvents(byId: id))
        #expect(fetched.latestRevision == 1)
        let read = fetched.events.compactMap { $0 as? ContractEvent }
        #expect(read.map(\.id) == events.map { $0.id })
        #expect(read.map(\.value) == [1, 2])
        #expect(read.map(\.metadata?.tag) == ["m", "m"])
        #expect(try await second.append(events: [ContractEvent(aggregateRootId: id, value: 3)], byId: id, version: 1, metadata: nil) == 2)
        await second.close()
    }

    @Test("purge survives reopen and removes the payload from the stream file")
    func purgeSurvivesReopenAndDropsPayload() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let event = ContractEvent(aggregateRootId: id, value: 7)
        let file = try fileURL(directory, id: id)

        let first = try open(directory)
        _ = try await first.append(events: [event], byId: id, version: nil, metadata: ContractMetadata(tag: "secret"))
        let before = try JSONDecoder().decode(StreamFile.self, from: Data(contentsOf: file))
        let payload = try #require(before.records.first?.payload.base64EncodedString())
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(payload))
        try await first.purge(byId: id)
        await first.close()

        let second = try open(directory)
        #expect(try await second.fetchEvents(byId: id) == nil)
        #expect(try await second.fetchEvents(byId: id, afterRevision: 0) == nil)
        #expect(await dddError {
            _ = try await second.append(events: [ContractEvent(aggregateRootId: id, value: 8)], byId: id, version: nil, metadata: nil)
        }?.code == .streamPurged)

        let bytes = try Data(contentsOf: file)
        let after = try JSONDecoder().decode(StreamFile.self, from: bytes)
        #expect(after.purged)
        #expect(after.records.isEmpty)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(payload))
        #expect(!text.contains(event.id.uuidString))
        await second.close()
    }

    @Test("a corrupted stream file fails reads and appends without being rewritten", arguments: Corruption.allCases)
    func corruptedStream(_ corruption: Corruption) async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let broken = UUID().uuidString
        let healthy = UUID().uuidString
        _ = try await store.append(events: [ContractEvent(aggregateRootId: broken, value: 1)], byId: broken, version: nil, metadata: nil)
        let healthyEvent = ContractEvent(aggregateRootId: healthy, value: 2)
        _ = try await store.append(events: [healthyEvent], byId: healthy, version: nil, metadata: nil)

        let brokenFile = try fileURL(directory, id: broken)
        let original = try Data(contentsOf: brokenFile)
        let corrupted: Data
        switch corruption {
        case .truncated:
            corrupted = original.prefix(original.count / 2)
        case .empty:
            corrupted = Data()
        case .futureFormat:
            var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            json["formatVersion"] = 2
            corrupted = try JSONSerialization.data(withJSONObject: json)
        case .wrongStream:
            corrupted = try Data(contentsOf: fileURL(directory, id: healthy))
        }
        try corrupted.write(to: brokenFile)
        let brokenStream = ContractStream.getStreamName(id: broken)

        #expect(await dddError { _ = try await store.fetchEvents(byId: broken) }?.corruptedStream == brokenStream)
        #expect(await dddError { _ = try await store.fetchEvents(byId: broken, afterRevision: 0) }?.corruptedStream == brokenStream)
        for version: UInt64? in [nil, 0] {
            #expect(await dddError {
                _ = try await store.append(events: [ContractEvent(aggregateRootId: broken, value: 3)], byId: broken, version: version, metadata: nil)
            }?.corruptedStream == brokenStream)
        }
        #expect(try Data(contentsOf: brokenFile) == corrupted)
        #expect(try await store.fetchEvents(byId: healthy)?.events.map { $0.id } == [healthyEvent.id])

        try await store.purge(byId: broken)
        #expect(try await store.fetchEvents(byId: broken) == nil)
        #expect(try await store.fetchEvents(byId: healthy)?.events.map { $0.id } == [healthyEvent.id])
        await store.close()
    }

    @Test("stream names that differ only in case use separate files")
    func caseSensitiveStreamNames() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let lower = "case-\(UUID().uuidString.lowercased())"
        let upper = lower.uppercased()
        let lowerEvent = ContractEvent(aggregateRootId: lower, value: 1)
        let upperEvent = ContractEvent(aggregateRootId: upper, value: 2)

        _ = try await store.append(events: [lowerEvent], byId: lower, version: nil, metadata: nil)
        _ = try await store.append(events: [upperEvent], byId: upper, version: nil, metadata: nil)

        #expect(try await store.fetchEvents(byId: lower)?.events.map { $0.id } == [lowerEvent.id])
        #expect(try await store.fetchEvents(byId: upper)?.events.map { $0.id } == [upperEvent.id])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(names.contains(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: lower))))
        #expect(names.contains(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: upper))))
        await store.close()
    }

    @Test("a stream name over 120 UTF-8 bytes is rejected by every operation")
    func streamNameTooLong() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let prefixBytes = ContractStream.getStreamName(id: "").utf8.count
        let longest = String(repeating: "x", count: 120 - prefixBytes)
        let tooLong = longest + "x"

        #expect(try await store.append(events: [ContractEvent(aggregateRootId: longest, value: 1)], byId: longest, version: nil, metadata: nil) == 0)

        let event = ContractEvent(aggregateRootId: tooLong, value: 1)
        #expect(await dddError { _ = try await store.append(events: [event], byId: tooLong, version: nil, metadata: nil) }?
            .storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { _ = try await store.fetchEvents(byId: tooLong) }?.storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { _ = try await store.fetchEvents(byId: tooLong, afterRevision: 0) }?
            .storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { try await store.purge(byId: tooLong) }?.storeUnavailableReason == .streamNameTooLong)
        await store.close()
    }

    @Test("a closed store rejects every operation except an empty append")
    func closedStoreRejectsOperations() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let id = UUID().uuidString
        await store.close()

        #expect(try await store.append(events: [], byId: id, version: nil, metadata: nil) == nil)
        let event = ContractEvent(aggregateRootId: id, value: 1)
        #expect(await dddError { _ = try await store.append(events: [event], byId: id, version: nil, metadata: nil) }?
            .storeUnavailableReason == .closed)
        #expect(await dddError { _ = try await store.fetchEvents(byId: id) }?.storeUnavailableReason == .closed)
        #expect(await dddError { _ = try await store.fetchEvents(byId: id, afterRevision: 0) }?.storeUnavailableReason == .closed)
        #expect(await dddError { try await store.purge(byId: id) }?.storeUnavailableReason == .closed)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter PersistentEventStoreFileTests`
Expected: all pass (4 corruption cases count as 4). If one fails, fix the store and say why in the commit message body.

- [ ] **Step 3: Commit**

```bash
git add Tests/LocalEventStoreTests Sources/LocalEventStore
git commit -m "test(local-store): pin reopen, purge, corruption, file names and closed-store behaviour

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 6: Repository and projector share one instance

**Files:**
- Test: `Tests/LocalEventStoreTests/SharedInstanceTests.swift`

- [ ] **Step 1: Write the test**

`Tests/LocalEventStoreTests/SharedInstanceTests.swift`:

```swift
import Foundation
import Testing
@testable import DDDCore
@testable import EventSourcing
import LocalEventStore

private struct TestMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct WidgetCreated: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var name: String
}

private struct WidgetRenamed: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var name: String
}

private final class Widget: AggregateRoot, @unchecked Sendable {
    struct WidgetDeleted: DeletedEvent {
        typealias Metadata = TestMetadata
        var id: UUID = .init()
        var occurred: Date = .now
        var aggregateRootId: String
        var metadata: TestMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = WidgetDeleted

    let id: String
    private(set) var name: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, name: String) throws {
        self.id = id
        try apply(event: WidgetCreated(aggregateRootId: id, name: name))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? WidgetCreated else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func rename(to name: String) throws {
        try apply(event: WidgetRenamed(aggregateRootId: id, name: name))
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as WidgetCreated: name = e.name
        case let e as WidgetRenamed: name = e.name
        case is WidgetDeleted: metadata.delete()
        default: break
        }
    }
}

private struct WidgetMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "WidgetCreated": return try eventData.decode(to: WidgetCreated.self)
        case "WidgetRenamed": return try eventData.decode(to: WidgetRenamed.self)
        default: return nil
        }
    }
}

private typealias WidgetStore = PersistentEventStore<Widget, TestMetadata>

private final class WidgetRepository: EventSourcingRepository {
    typealias AggregateRootType = Widget
    typealias Store = WidgetStore

    let store: WidgetStore

    init(store: WidgetStore) {
        self.store = store
    }
}

private struct WidgetInput: CQRSProjectorInput {
    let id: String
}

private struct WidgetView: ReadModel {
    let id: String
    var name: String
    var renames: Int
}

private struct WidgetProjector: EventSourcingProjector {
    typealias Input = WidgetInput
    typealias ReadModelType = WidgetView
    typealias Store = WidgetStore

    let store: WidgetStore

    func buildReadModel(input: WidgetInput) throws -> WidgetView? {
        WidgetView(id: input.id, name: "", renames: 0)
    }

    func apply(readModel: inout WidgetView, events: [any DomainEvent]) throws {
        for event in events {
            switch event {
            case let e as WidgetCreated:
                readModel.name = e.name
            case let e as WidgetRenamed:
                readModel.name = e.name
                readModel.renames += 1
            default:
                break
            }
        }
    }
}

@Suite("PersistentEventStore shared by repository and projector")
struct SharedInstanceTests {

    @Test("the projector reads what the repository saved through the same instance")
    func projectorReadsRepositoryWrites() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WidgetStore.open(directory: directory, eventMapper: WidgetMapper())
        let repository = WidgetRepository(store: store)
        let projector = WidgetProjector(store: store)

        try await repository.save(aggregateRoot: try Widget(id: "w-1", name: "alpha"))
        let found = try #require(try await repository.find(byId: "w-1"))
        #expect(found.version == 0)
        try found.rename(to: "beta")
        try await repository.save(aggregateRoot: found)

        let output = try #require(try await projector.execute(input: WidgetInput(id: "w-1")))
        #expect(output.readModel.name == "beta")
        #expect(output.readModel.renames == 1)
        await store.close()
    }
}
```

`makeTemporaryDirectory()` is the module-level helper defined in `PersistentEventStoreLifecycleTests.swift`.

- [ ] **Step 2: Run it**

Run: `swift test --filter SharedInstanceTests`
Expected: 1 test passed.

- [ ] **Step 3: Commit**

```bash
git add Tests/LocalEventStoreTests/SharedInstanceTests.swift
git commit -m "test(local-store): repository and projector share one PersistentEventStore

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
```

---

### Task 7: Umbrella re-export, CLAUDE.md, verification and PR

**Files:**
- Modify: `Package.swift` (`DDDKit` target dependencies), `Sources/DDDKit/DDDKit.swift`, `CLAUDE.md`

- [ ] **Step 1: Re-export from `DDDKit`**

In `Package.swift`, add `"LocalEventStore",` to the `DDDKit` target's dependencies after `"EventSourcing",`.

In `Sources/DDDKit/DDDKit.swift` add after `@_exported import EventSourcing`:

```swift
@_exported import LocalEventStore
```

- [ ] **Step 2: Update CLAUDE.md**

- In the layer tree, add after the `EventSourcing` line: `├── LocalEventStore  — PersistentEventStore: file-backed EventStore (one JSON file per stream, atomic writes, one open instance per directory)`.
- In Build & Test, add: "`LocalEventStoreTests` covers `PersistentEventStore` on disk (temporary directories, no services); `EventStoreContractTests` also runs the contract against it."
- Under Key Protocols, add:

```markdown
**`PersistentEventStore<StreamNaming, Metadata>`** (LocalEventStore) — `EventStore` backed by a directory: `<hex of stream name>.json` per stream, whole file replaced with `Data.write(.atomic)` on every append, `purge` rewrites it as `purged: true` with no records (the payload leaves the file; also clears a corrupted stream, and the id stays unwritable). `open(directory:eventMapper:)` takes a `flock` on `<directory>/.lock` (second open → `storeUnavailable(.occupied)`), `close()` releases it. Share one instance between the repository and the projectors. Not durable across power loss (no fsync). Errors: `storeUnavailable` (503, `error.storeUnavailableReason`) and `storeCorrupted` (504, `error.corruptedStream`).
```

- [ ] **Step 3: Full verification**

Run:

```bash
swift build --build-tests
swift test --no-parallel --filter '(DDDKitUnitTests|EventSourcingTests|KurrentSupportInMemoryTests|KurrentSupportUnitTests|ReadModelPersistenceTests|DomainEventGeneratorTests|ProjectorGeneratorFixtureTests|EventStoreContractTests|LocalEventStoreTests)'
bash scripts/emit-symbol-graphs.sh . "$(mktemp -d)"
```

Expected: build complete; every test run passes; the symbol-graph script exits 0 (`LocalEventStore` is a library target and needs no exclusion).

- [ ] **Step 4: Commit, push and open the PR against `main`**

```bash
git add Package.swift Sources/DDDKit/DDDKit.swift CLAUDE.md
git commit -m "feat(local-store): re-export LocalEventStore from DDDKit; document it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KkjJk5kLGaVQcPt4wa7MT1"
git push -u origin feat/persistent-event-store
gh pr create --base main --title "PersistentEventStore (1.5, part B)" --body "…"
```

The PR body lists what the target adds, links the spec, states that it builds on spec A from #31 (merged), lists the tests, and says that the product, iOS platform and CI filter come with part C. End it with the PR attribution lines. Stop after opening the PR. Do not merge.

---

## Self-review

- **Spec coverage:** §2 API (Task 3, 4), §3 directory and file names (Task 2, 3, 5), §3 corrupted-file rules (Task 4 `load`, Task 5 `corruptedStream`), §4 operations including empty-append precedence and no cache (Task 4), §4 purge without decoding (Task 4, Task 5), §5 durability notes (doc comment, Task 3), §6 single opener and deinit (Task 3), §7 every listed test (Tasks 3, 5, 6; contract in Task 4). Product, `.iOS(.v18)` and CI filters are spec C and are not here.
- **Deviations from the spec text:** none intended. `storeUnavailable` carries `path` and an optional `detail` besides the reason, which the spec does not forbid.
- **Shared code instead of copies:** the id de-duplication rule exists once (`package func idempotentRevision` in EventSourcing) and both `InMemoryEventStore` and `PersistentEventStore` call it. `InMemoryEventStoreClient` keeps its own copy because it models KurrentDB's `StreamRevision` expectations, not the `EventStore` contract.
- **Known risk:** `CocoaError.fileReadNoSuchFile` on Linux. swift-foundation maps `ENOENT` to that code for `Data(contentsOf:)`; if Linux CI (plan C) shows otherwise, extend the catch to also check the underlying `POSIXError(.ENOENT)`.
