# ``KurrentSupport``

Store events in KurrentDB and project them with persistent subscriptions.

## Overview

``KurrentStorageCoordinator`` is the KurrentDB `EventStore`. It reaches KurrentDB through the
narrow ``EventStoreClient`` seam: ``LiveEventStoreClient`` wraps a real `KurrentDBClient`, and
`InMemoryEventStoreClient` (`KurrentSupportInMemory`) needs no server. Inside `withUnitOfWork` the
coordinator stages its appends and commits them together with the block's other saves.

## Topics

### Essentials

- <doc:UnitOfWork>

### Storing events

- ``KurrentStorageCoordinator``
- ``EventStoreClient``
- ``LiveEventStoreClient``
- ``EventStoreClientError``

### Atomic multi-stream appends

- ``StreamBatch``
- ``StreamBatchResult``
- ``StreamConflict``
