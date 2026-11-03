# ``EventSourcing``

Event-sourcing building blocks that do not depend on a particular event store.

## Overview

An ``EventSourcingRepository`` rebuilds an aggregate from its events and appends the new ones
through an ``EventStore``. Every store follows one contract: revisions start at 0, a version
mismatch throws `DDDError.commitConflict`, and `purge` is permanent. ``withUnitOfWork(_:)``
commits the saves of several usecases together, or none of them.

## Topics

### Essentials

- <doc:ComposingUsecases>

### Repositories and stores

- ``EventSourcingRepository``
- ``EventStore``
- ``InMemoryEventStore``

### Unit of work

- ``withUnitOfWork(_:)``
- ``UnitOfWork``
- ``UnitOfWorkBackend``
- ``UnitOfWorkParticipant``
