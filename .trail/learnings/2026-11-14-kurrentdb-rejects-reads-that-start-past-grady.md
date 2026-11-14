---
title: "KurrentDB rejects reads that start past Int64.max or at the end, and soft-deleted streams continue from their old tail"
author: Grady
date: 2026-11-14
branch: main
cost: { minutes: 23, tokens: 291253 }
id: l-983beb42
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
- Reads after a given revision start at Int64.max at most. Reading forward from a revision beyond Int64.max fails on the server with a gRPC error, and computing revision + 1 traps at UInt64.max. No record can follow such a revision, so the window is empty (or the stream is not found).
- The in-memory KurrentDB fake copies the server's soft delete, checked live on 26.1.3. A deleted stream reads as not found but keeps its tail T. A write expecting no stream, T or any revision recreates it from T+1. Another exact revision conflicts with current T. Expecting the stream to exist throws resourceDeleted. Deleting it again with any, T or no stream is fine. A resend of the recreating batch is idempotent.
- A stream name without a dash belongs to no category on a real cluster, so no $ce- stream ever gets its events. The fake does the same.
- The reported latest revision stays the last *mapped* event. That is contract rule 3.2, not a bug: old code must not write after events it cannot read. A review note called it a bug; it was dropped after reading the contract spec.

## Tried and ruled out
- Reading from `.end` to mean "nothing after this": the server rejects a forward read from the end ("fromEventNumber should be non negative").

## Watch out
- Running a local KurrentDB on a non-default host port: the client follows gossip to the advertised node port. Map the same port inside and out (KURRENTDB_NODE_PORT=2123, -p 2123:2123) or the client reports "node not found". The test pool connects only then.
- The 3-node cluster on 2111–2113 belongs to someone else; use another port.

In the code: Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift fetchEvents(byId:afterRevision:) cursor; Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift deletedTails, systemCategory; docs/superpowers/specs/2026-10-23-eventstore-contract-design.md §3.2; live test LiveKurrentContract.fetchAfterHugeRevision (PR #42).
