# ``ReadModelPersistence``

Persist read model snapshots with the revision they were folded up to.

## Overview

A snapshot is a cache of a projection, never the source of truth: the event store is. Any
snapshot can be thrown away and rebuilt by replaying events, which is how schema changes are
handled.

## Topics

### Essentials

- <doc:SchemaEvolutionAndRebuilding>

### Stores

- ``ReadModelStore``
- ``TransactionalReadModelStore``
- ``InMemoryReadModelStore``
- ``StoredReadModel``

### Rebuilding

- ``ReadModelSnapshotPurging``
