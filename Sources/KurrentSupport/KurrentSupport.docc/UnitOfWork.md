# Unit of work on KurrentDB

How `KurrentStorageCoordinator` takes part in `withUnitOfWork`, and what an `EventStoreClient`
has to provide for it.

## Overview

``KurrentStorageCoordinator`` is a `UnitOfWorkParticipant`. Outside `withUnitOfWork` it behaves
exactly as before. Inside, its appends are staged in the scope's backend and written together
when the block returns: one stream through the same single-stream append as a plain `save`, two
or more through one KurrentDB `AppendRecords` call. How to compose usecases with
`withUnitOfWork`, and the rules inside the block, are in the `EventSourcing` article "Composing
usecases with a unit of work".

## Saving inside a scope

- `append` stages the events and returns the revision the last of them is predicted to get:
  `count - 1` for a new stream (`.noStream`), `n + count` after revision `n`. The repository
  updates the aggregate's version with it, as it does after a real append.
- A second save of the same stream must expect the tail the first one predicted; its events join
  the same batch, which keeps the first expected revision. Any other expected revision throws
  `DDDError.commitConflict` at once. So when two concurrent tasks in a scope both find one
  aggregate before either saves it, the second save fails, and so does the second save of two
  aggregate types whose stream names collide.
- Empty `append`s and expected revisions beyond `Int64.max` behave as outside a scope.
- An event whose payload cannot be encoded makes `save` throw its `EncodingError` at once; nothing
  is staged, and the repository fails the unit of work.
- Every save checks that AppendRecords can carry its metadata; see
  <doc:UnitOfWork#Metadata-inside-a-scope>.
- `purge` throws `DDDError.operationNotAllow(operation: "purge", reason: "not allowed inside a
  unit of work")` without touching the stream.

## Reading inside a scope

`fetchEvents(byId:)` and `fetchEvents(byId:afterRevision:)` read the server first, then add the
events the scope has staged for the stream, numbered from the batch's own expected revision
(`.noStream` → from 0, `.at(n)` → from `n + 1`). Both go through the same `eventMapper`, so a
staged event's `metadata` is filled the same way as a stored one's. A stream the server does not
have returns only the staged events; the `afterRevision` filter applies to all of them, and
`latestRevision` is the last staged revision whenever something is staged.

Every reader through a coordinator whose client has the scope's identity sees the staged events,
including an `EventSourcingProjector` run synchronously inside the scope. Read model snapshots are
written to another store and are not part of the unit of work, so such a projector would fold
events that a failed commit never writes. Run projections on the ``KurrentProjection``
subscription runners: they run in their own task, outside any scope.

A read never creates, binds or fails on the scope's backend, so a usecase may read through a
repository over another `KurrentDBClient`; only writes bind the scope to a client. Such a read
sees only what the server has, not the events the scope staged through its own client. A usecase
that reads what an earlier usecase in the same block saved needs a repository over the same
`KurrentDBClient` instance.

## One client per unit of work

All writes of one scope go through one client, chosen by ``EventStoreClient/identity``:
coordinators whose clients report the same identity share the scope's backend, and a write
through a client with another identity throws `DDDError.operationNotAllow`. A unit of work cannot
span two clusters.

``LiveEventStoreClient`` reports the identity of the `KurrentDBClient` it wraps, so coordinators
built with `init(client: KurrentDBClient, eventMapper:)` over the same `KurrentDBClient` instance
commit together and the composition root needs no change. The identity is the instance, not the
cluster: two `KurrentDBClient` instances connected to the same cluster (two
`KurrentDBPool.borrow()` results, say) count as two, and the second one's write throws. Every
`InMemoryEventStoreClient` instance is an identity of its own.

## Commit

| Staged streams | Commit |
|---|---|
| none | nothing is sent |
| one | the single-stream `append`, with the same behaviour, errors and resend handling as a `save` outside a scope |
| two or more | one ``EventStoreClient/appendAtomically(_:)`` call: KurrentDB's `AppendRecords`, which checks every stream's expected revision before writing anything (KurrentDB 26.1 or later) |

Errors become the `EventStore` contract's:

| Error | Thrown as |
|---|---|
| `EventStoreClientError.wrongExpectedRevision`, `KurrentError.wrongExpectedVersion` | `DDDError.commitConflict(id:expected:actual:)` |
| ``EventStoreClientError/consistencyViolations(_:)`` | `DDDError.commitConflict(conflicts:)`; `error.commitConflicts` has one entry per conflicting stream, in batch order |
| `KurrentError.resourceDeleted` (a purged stream) | `DDDError.streamPurged(id:)`, also when other streams of the same commit conflict |
| `KurrentError.unsupportedFeature` (a server older than 26.1) | `DDDError.operationNotAllow(operation: "commit", reason: "server does not support AppendRecords (KurrentDB 26.1+)")` |
| ``EventStoreClientError/atomicAppendUnsupported`` and any other error | unchanged |

After `commitConflict` or `streamPurged` nothing was written. After any other error the writes
may have landed (the response can be lost after the server committed, and the client retries on
node failures): read the streams before running the block again.

When the server returns another revision than the predicted one, the commit logs a warning and
succeeds: the server's revision is the true one, the events are stored, and the hooks run. It
happens, for example, when a stream that was soft-deleted is recreated: it continues from the old
tail + 1 instead of 0. The aggregate instances from the block then carry a lower version than the
server, so find them again instead of reusing them.

## Metadata inside a scope

`AppendRecords` carries custom metadata as protobuf properties instead of raw bytes, and whether
a scope ends up writing one stream or several is unknown at `save`. So every save inside a scope
checks that its metadata encodes to a JSON object. A type that encodes to a scalar (a
`String`-backed enum, say) throws `DDDError.operationNotAllow(operation: "save", reason: "Metadata
cannot be carried by AppendRecords: …")` at `save`, not at commit. `nil` metadata is not checked,
and outside a scope such metadata is still written as before.

NaN and ±infinity never reach that check: the coordinator encodes metadata with a default
`JSONEncoder`, which throws `EncodingError` for them at `save`, inside a scope and outside it, as
before 1.5. Inside a scope that error fails the unit of work like any other store error.

Numbers are not checked further. `AppendRecords` sends every number as the nearest `Double`, so
when the scope writes two or more streams, an integer that a `Double` cannot hold exactly (beyond
±2^53, including one beyond 64 bits, such as a large `Decimal`) is stored rounded, without an
error. A one-stream commit, like every save outside a scope, keeps the exact bytes. Store values
whose every digit matters as strings.

On read, KurrentDB adds `$schema.name` and `$schema.format` keys to the custom metadata of every
event written through `AppendRecords`, that is, every event of a commit that writes two or more
streams. A struct decodes as before, because `JSONDecoder` ignores keys it does not know; compare
decoded values, not raw bytes or dictionaries.

The keys are added also when the event carries no metadata. Saved with `nil` metadata (no
`EventMetadataContext` around the `save`) in a commit of two or more streams, an event reads back
with custom metadata `{"$schema.name": "<event type>", "$schema.format": "Json"}`, not empty bytes.
A one-stream commit, like every save outside a scope, still leaves it empty, and
`InMemoryEventStoreClient` stores custom metadata as written and adds no keys. For code that
reads it:

- The mapper `generate event` emits decodes metadata with `try?`. A metadata type with a required
  field, such as `CustomMetadata`, gives `event.metadata == nil`, as for empty bytes; a type whose
  fields are all optional gives a value with every field `nil` instead of `nil`.
- Code that reads `customMetadata` itself must not take non-empty bytes to mean that metadata was
  written: decode with `try?` or with optional fields, and treat a failure as no metadata. A
  hand-written `EventTypeMapper` that throws on such an event makes the coordinator skip it with
  a warning, so `find` rebuilds the aggregate without that event.
- `ContextForwarder` takes custom metadata that holds only `$schema.*` keys as absent:
  `ForwardedRecord.metadata` is `nil` and `decodeMetadata(_:)` returns `nil` for such an event.

## Writing an EventStoreClient

``EventStoreClient/identity`` has no default implementation: taking two clusters for one would
send events to the wrong cluster. A wrapper forwards the identity of the client it wraps.

``EventStoreClient/appendAtomically(_:)`` has a deprecated default that throws
``EventStoreClientError/atomicAppendUnsupported``, so a conformance written before 1.5 still
compiles (with a warning), but a unit of work that writes two or more streams through it fails
at commit. A wrapper forwards it too:

```swift
struct LoggingClient: EventStoreClient {
    let base: any EventStoreClient
    // ...other requirements...
    var identity: ObjectIdentifier { base.identity }

    func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        try await base.appendAtomically(batches)
    }
}
```

An implementation of `appendAtomically(_:)` receives at least two ``StreamBatch`` values with
distinct streams. It checks every expected revision before writing anything. When a stream is
tombstoned it throws `KurrentError.resourceDeleted` naming the first such stream in batch order,
even when other streams conflict too; otherwise, when any expected revision does not hold, it
throws ``EventStoreClientError/consistencyViolations(_:)`` with one ``StreamConflict`` per such
stream, in any order (`current` is `nil` for a stream that does not exist), and writes nothing;
the unit-of-work backend reports the conflicts in its own batch order. It returns each
stream's new revision as a ``StreamBatchResult``, in no particular order. Resending a whole
request with the same event ids returns the original revisions and writes nothing.
