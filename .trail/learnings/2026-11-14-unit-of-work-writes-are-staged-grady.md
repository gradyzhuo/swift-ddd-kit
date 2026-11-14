---
title: "Unit-of-work writes are staged under the scope's own lock, so nothing can land after the scope closes"
author: Grady
date: 2026-11-14
branch: feat/unit-of-work
cost: { minutes: 210, tokens: 3347893 }
id: l-60f72763
scope: repo
status: active
src: agent
touches:
  - Tests/EventSourcingTests/UnitOfWorkTests.swift
  - Tests/KurrentLiveContractTests/UnitOfWorkLiveTests.swift
  - Tests/KurrentSupportInMemoryTests/KurrentStorageCoordinatorUnitOfWorkTests.swift
  - docs/superpowers/specs/2026-11-01-unit-of-work-design.md
  - Sources/ContextForwarder/ForwardedRecord.swift
  - Tests/ContextForwarderTests/ForwardedRecordTests.swift
  - CLAUDE.md
  - MIGRATION.md
  - Sources/EventSourcing/EventSourcing.docc/ComposingUsecases.md
  - Sources/KurrentSupport/KurrentSupport.docc/UnitOfWork.md
---

## Decided
The scope's backend is only reachable through a closure that runs while the scope's lock is held, the same lock the end of the scope takes. A write therefore either lands before the scope closes and is committed, or sees the scope closed and throws. The framework guarantees this for every backend; a backend does not have to implement its own refusal.

## Tried and ruled out
Handing the backend out of the lock and staging on it afterwards (the first design). A task that outlived the block could fetch the backend, lose the race to the close, then stage: into a backend dropped with a failed scope (save returned a revision that was never written) or into a commit already under way. A "close" hook on each backend was also considered and rejected: every third-party backend would have to get the refusal right.

## Watch out
- Code inside the closure must not call back into the scope (the lock is not reentrant).
- A backend reference kept after the closure returns is no longer guarded.
- Swift on Linux rejects a Task closure that captures a local Mutex the test keeps using (SendingClosureRisksDataRace); macOS let it through. Capture a Sendable class instead.

In the code: UnitOfWork.withBackend(_:identity:make:_:) in Sources/EventSourcing/UnitOfWork/UnitOfWork.swift replaced backend(_:identity:make:); KurrentStorageCoordinator stages inside it. Pinned by UnitOfWorkTests.scopeEndWaitsForRunningBody (fails if the body moves outside the lock) and withBackendAfterEndNeverRunsBody.
