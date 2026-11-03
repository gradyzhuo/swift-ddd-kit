# Composing usecases with a unit of work

Commit the saves of several usecases together, or none of them.

## Overview

An operation sometimes changes two aggregates that must succeed or fail together: create a
QuotingCase and open its BillingAccount, say. Saving one and then the other leaves the first one
written when the second fails, and there is no compensation. ``withUnitOfWork(_:)`` collects every
`repository.save` made inside its block and commits them together when the block returns. When
the block throws, nothing is written.

Existing usecases, repositories and generated code take part unchanged, and so does the
composition root: services built once at startup are called inside the block like anywhere else.
A usecase does not know it runs inside a unit of work. Outside a block nothing changes:
`repository.save` writes straight to the store, as before.

### Compose two usecases

```swift
func createQuotingCaseWithContact(_ input: Input) async throws -> Output {
    let quoting = try await withUnitOfWork { _ in
        let quoting = try await createQuotingCaseService.execute(
            input: .init(operatorId: input.operatorId, name: input.name))
        try await addContactService.execute(
            input: .init(operatorId: input.operatorId, quotingCaseId: quoting.id, contact: input.contact))
        return quoting
    }
    return .created(quoting)
}
```

Both services are the instances built at startup, and their repositories share one store client
(on KurrentDB, one `KurrentDBClient` instance). So the `repository.find(byId: quoting.id)` inside
`addContactService` finds the QuotingCase that was just created and is not written yet, and its
`save` joins the same stream's batch. A repository over another `KurrentDBClient` instance would
read only what the server has and not find it.

### Change two aggregates

```swift
try await withUnitOfWork { _ in
    let quoting = try await createQuotingCaseService.execute(
        input: .init(operatorId: input.operatorId, name: input.name))       // QuotingCase-xxx
    try await openBillingAccountService.execute(input: .init(for: quoting.id)) // BillingAccount-yyy
}
```

Two streams, one atomic append. When either stream is not at its expected revision, the whole
batch is rejected with `DDDError.commitConflict`, and `error.commitConflicts` lists every
conflicting stream.

### Test without a server

`KurrentStorageCoordinator` takes part over `InMemoryEventStoreClient` (`KurrentSupportInMemory`)
as well, so a test needs no server:

```swift
let client = InMemoryEventStoreClient()
let repository = QuotingCaseRepository(store: .init(client: client, eventMapper: QuotingCaseEventMapper()))
let service = CreateQuotingCaseService(repository: repository)
try await withUnitOfWork { _ in try await service.execute(input: input) }   // no server
```

``InMemoryEventStore`` does not take part; see <doc:ComposingUsecases#Stores-that-take-part>.

### Metadata

Each usecase's own `EventMetadataContext<M>.withValue` value travels with that usecase's events;
there is no need to set it again around `withUnitOfWork`. Repositories with different `Metadata`
types can save in one block.

## The work parameter

```swift
let quoting = try await withUnitOfWork { work in
    let quoting = try await createQuotingCaseService.execute(
        input: .init(operatorId: input.operatorId, name: input.name))
    try await openBillingAccountService.execute(input: .init(for: quoting.id))
    try work.onCommitted { try await notifier.send(.quotingCreated(quoting.id)) }   // after the commit
    return quoting
}
```

| Member | Purpose |
|---|---|
| ``UnitOfWork/id`` | Identifies the scope, for correlating logs. Every scope has its own. |
| ``UnitOfWork/isFailed`` | True once ``UnitOfWork/fail(_:)`` was called, by the caller or by the framework (see <doc:ComposingUsecases#How-a-unit-of-work-ends>). |
| ``UnitOfWork/fail(_:)`` | Marks the scope failed without throwing. The block may go on and return normally, but nothing is committed and `withUnitOfWork` throws `DDDError.operationNotAllow(operation: "commit", reason: "unit of work failed")` with the first cause in `userInfos["cause"]`. For a handler that returns a normal failure output and discards the writes. |
| ``UnitOfWork/onCommitted(_:)`` | Registers a side effect (an event bus, a notification, an external API) to run after a successful commit. |

Hooks run in registration order, one at a time, before `withUnitOfWork` returns. None of them runs
when the block throws, the scope was failed, or the commit failed. A scope without any write
counts as committed, so its hooks run. A hook that throws stops the later ones and its error is
thrown from `withUnitOfWork`, **but the commit has already landed**: catch inside the hook
whatever must not fail the call. Hooks run outside the scope: inside a hook
``UnitOfWork/current`` is `nil`, so a `repository.save` there writes straight to the store and is
not part of the atomic commit.

A usecase that must work both inside and outside a scope:

```swift
if let work = UnitOfWork.current {
    try work.onCommitted { try await notifier.send(.quotingCreated(id)) }
} else {
    try await notifier.send(.quotingCreated(id))
}
```

``UnitOfWork/fail(_:)`` and ``UnitOfWork/onCommitted(_:)`` throw `operationNotAllow` once the
scope has ended, which is why both are called with `try`.

## Rules inside the block

- **No nesting.** `withUnitOfWork` inside a scope throws `operationNotAllow` without running its
  block, and the outer scope is not affected. A usecase does not call `withUnitOfWork`; it belongs
  to the handler. When two handlers share logic, extract a function that does not open a scope
  and let each handler wrap it.
- **Do not `do/catch` a usecase's error inside the block.** To return a normal failure output,
  call `try work.fail(error)` and return. What goes wrong otherwise is a usecase that saves, then
  throws, and is caught: store errors in the default repository methods fail the scope
  automatically (see <doc:ComposingUsecases#How-a-unit-of-work-ends>), and this rule covers the
  rest.
- **Do not move a `save` into `Task { … }`.** A task that is not detached inherits the scope. If
  it reaches `save` after the block ended, it hits the closed scope and throws `operationNotAllow`;
  it never writes directly and never joins a batch that was already committed. Await everything
  the scope must do before returning.
- **Do not move a `save` out of the task tree either.** `Task.detached`, and code that does not
  run in the block's task tree (a NIO future callback, a `DispatchQueue` block, a timer), do not
  see the scope at all: ``UnitOfWork/current`` is `nil` there, so a `save` writes to the store at
  once, is not part of the commit, and stays written when the block throws or the commit fails.
  Use `async let` or a `TaskGroup` to run usecases in parallel inside the block.
- **Publish after the commit.** A usecase that calls `EventBus.publish` right after `save`
  publishes before the commit inside a scope. To be right in and out of a scope, write
  `if let work = UnitOfWork.current { try work.onCommitted { … } } else { … }`.
- **Run different aggregates concurrently, never the same one.** `async let` and `TaskGroup` may
  run usecases on **different** aggregates in one scope. Changing the same aggregate concurrently
  is not supported: when both tasks found the aggregate before either saved it, the second `save`
  throws `commitConflict`.

There is no early `commit()` or `rollback()`, no way to write directly from inside a scope, and no
query of what is staged (tests assert on the store). `withUnitOfWork` takes no other parameters.

## How a unit of work ends

1. The block returns or throws, and the scope closes at once. From then on
   ``UnitOfWork/backend(_:identity:make:)``, ``UnitOfWork/fail(_:)`` and
   ``UnitOfWork/onCommitted(_:)`` throw `operationNotAllow`, also from a `Task` started in the
   block, which still sees the scope as ``UnitOfWork/current``.
2. The block threw (`CancellationError` included): nothing is committed, no hook runs, and the
   error is rethrown.
3. The scope was failed: nothing is committed, no hook runs, and `withUnitOfWork` throws
   `DDDError.operationNotAllow(operation: "commit", reason: "unit of work failed")`, with the first
   cause in `userInfos["cause"]`.
4. Otherwise the scope's backend, if a store registered one, commits. After `commitConflict` or
   `streamPurged` nothing was written. After any other commit error (a transport error, a server
   or client that cannot append several streams at once) the writes **may have landed**, for
   example when the response was lost after the server committed: read the streams before running
   the block again.
5. The ``UnitOfWork/onCommitted(_:)`` hooks run, outside the scope.

The scope fails by itself when a store call made by ``EventSourcingRepository``'s default `find`,
`save`, `delete` or `purge` throws inside it, even when the caller catches the error: a
`commitConflict`, a `streamPurged`, a read error, or the refusal of a store that cannot take
part. So a write failure the framework sees never commits. The `aggregateNotFound` that `delete`
throws for a missing aggregate and the aggregate's own `markDelete` errors do not fail the scope:
nothing was written, and usecases often treat them as idempotent.

After the block, find aggregates again instead of reusing the instances from inside it. Their
version is the revision the store predicted when they were saved; after a block that threw it
still reflects the discarded save, and a server may assign other revisions than predicted.

## Stores that take part

A store takes part by conforming to ``UnitOfWorkParticipant``; `KurrentStorageCoordinator` does.
Inside a scope, ``EventSourcingRepository``'s default `save` and `purge` refuse any other store
(``InMemoryEventStore``, `PersistentEventStore`) with `operationNotAllow` rather than letting it
write directly. `save` refuses even when the aggregate has no new events; outside a scope, a save
without new events still returns without calling the store. `find` is never refused: reads have
no side effects. With this package's stores the default `purge` never runs inside a scope: the
repository refuses the stores that do not take part, and `KurrentStorageCoordinator` refuses it
itself, even when it is called directly.

The check and the automatic failure live in ``EventSourcingRepository``'s default
implementations only. A repository that overrides `find`, `save`, `delete` or `purge`, or code
that calls `store.append` or `store.purge` directly, gets neither: a store that does not take part
writes, or purges for good, at once even inside a scope, and a block that then throws does not
undo it.

Read models are not part of a unit of work. Reads through a participating store inside a scope
can see the staged events, so an ``EventSourcingProjector`` run synchronously inside a scope folds
events that may never be committed. Run projections on subscription runners, which run in their
own task outside any scope.

## Write a participating store

A store collects its writes in one ``UnitOfWorkBackend`` per scope and marks itself with
``UnitOfWorkParticipant``. Inside a scope, each write asks ``UnitOfWork/current`` for the backend
with ``UnitOfWork/backend(_:identity:make:)``, passing what the backend writes to as `identity`.
The scope keeps exactly one backend: a second type or identity throws `operationNotAllow`.
Looking up, creating (`make`) and storing happen under one lock, so concurrent first writes share
one backend; `make` must not call back into the scope. ``UnitOfWorkBackend/commit()`` is called at
most once, after a block that returned on a scope that was not failed; otherwise the backend is
dropped with what it collected.

A participant's `purge` must refuse inside a scope, as `KurrentStorageCoordinator.purge` does with
`DDDError.operationNotAllow(operation: "purge", …)`. The repository's default `purge` lets a
participant through, and a purge that ran at once would be permanent even when the block then
throws.
