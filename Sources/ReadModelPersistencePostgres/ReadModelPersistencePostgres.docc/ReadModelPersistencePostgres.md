# ``ReadModelPersistencePostgres``

Store read model snapshots in PostgreSQL as JSONB, written by a KurrentDB persistent subscription.

## Overview

Snapshots are a disposable projection cache: one row per `(id, type)` holding the read model as
JSONB plus the stream revision it was folded up to. Applications query the table with their own
SQL; recovery from any schema change is a rebuild, never a data migration.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:SnapshotWriteModes>

### Stores

- ``PostgresTransactionalReadModelStore``
- ``PostgresJSONReadModelStore``
- ``PostgresTransactionProvider``

### Schema and maintenance

- ``PostgresReadModelMigration``
- ``SnapshotWriteMode``
- ``PostgresReadModelSnapshots``
