# Changelog

All notable changes to PerunORM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-08-21

This patch release fixes resource retention after a unit of work leaves its transaction closure.

### Fixed

- A closed escaped `UnitOfWork` now releases its transaction and session execution context after
  draining operations already in flight, while continuing to reject all later calls.

### Changed

- Split session planning, state, and unit-of-work execution into focused source files without
  changing the public API.
- Documented the intended framework lifecycle: application-owned database/pool, request- or
  command-scoped `Session`, and closure-scoped `UnitOfWork`.

### Compatibility

- Source compatible with 0.2.0; no public symbols were added, removed, or changed.

## [0.2.0] - 2026-08-20

This release adds forward-only, transactional database migrations for PostgreSQL and SQLite.

### Added

- A fifth SwiftPM library product, `PerunMigrations`, depending only on `PerunDBAL` and usable
  without importing `PerunORM`.
- Ordered migration plans with stable ASCII identifiers, positive revisions, synchronous plan
  validation, and exact-prefix history reconciliation through `status()`.
- Atomic `migrate()` execution: the complete pending suffix runs sequentially in one exclusive
  transaction, and its tracking rows commit or roll back with the migrated database changes.
- Portable migration metadata creation and custom tracking-table names, with deterministic
  applied and pending references and reports containing only migrations committed by the call.
- `MigrationContext`, a closure-scoped SQL executor that rejects transaction-control commands,
  concurrent or escaped operations, delayed use after close, and continued work after a caught
  execution failure has made the migration rollback-only.
- `DatabaseLockKey` and the additive `ExclusiveTransactionDatabase` capability. PostgreSQL uses a
  transaction-scoped advisory lock with a fresh `READ COMMITTED` snapshot; SQLite acquires a
  database-wide write reservation with `BEGIN IMMEDIATE`.
- Portable `CREATE TABLE IF NOT EXISTS` rendering through a source-compatible dialect hook and a
  typed error for dialects that do not support the requested form.
- Shared SQLite and live PostgreSQL migration conformance suites covering fresh apply, restart
  no-op, append, rollback, cancellation, drift, concurrency, context misuse, metadata mutation,
  shutdown and reopen, and recovery after an unknown commit result.
- A standalone migration consumer-smoke package and a migration quick start showing initial
  status, first apply, restart no-op, and an appended migration.

### Changed

- `SQLExecutor` and `Transaction` now explicitly require exactly one meaningful top-level SQL
  statement per call and rejection of batches before the first statement executes, regardless of
  whether positional parameters are present.
- PostgreSQL rejects empty or comment-only SQL with `PostgresStatementError.emptyStatement`
  instead of normalizing the server's empty-query response as success.
- Transaction-control detection used by units of work and migrations now handles leading comments,
  empty semicolons, UTF-8 byte-order marks, and both PostgreSQL nested and SQLite flat block-comment
  interpretations conservatively.

### Compatibility

- Swift 6.0 or newer.
- macOS 13 or newer when building on macOS.
- The four 0.1 library products retain source compatibility; migrations are an additive product
  and capability.
- PostgreSQL through PerunPGSQL 0.3.x and SQLite through PerunSQLite 0.2.x.

### Known limitations

- Migrations are forward-only and append-only. Applied identifiers, revisions, and positions must
  not be edited, reordered, or removed; down migrations are not provided.
- The entire pending suffix uses one transaction. Per-migration commits, resuming in the middle of
  a pending release, and nontransactional migration steps are not supported.
- Migration SQL is limited to one meaningful top-level statement per execution. Transaction-control
  SQL is forbidden. Filesystem, network, and other external effects are not coordinated by the
  database transaction and must be retry-safe.
- Automatic schema diffing, schema introspection, qualified tracking schemas, and a migration CLI
  are not included.
- PostgreSQL deliberately serializes all Perun migrators in one logical database. SQLite provides
  the same safety by serializing all lock keys and may return `SQLITE_BUSY` when its configured busy
  timeout expires.
- A connection failure, timeout, or cancellation after commit begins can leave the result unknown.
  A subsequent `status()` or `migrate()` recovers from the committed tracking history without
  intentionally rerunning an already recorded migration.

## [0.1.0] - 2026-08-19

First public release of PerunORM.

### Added

- Four SwiftPM library products: `PerunDBAL`, `PerunDBALPostgres`, `PerunDBALSQLite`, and
  `PerunORM`.
- A backend-neutral async DBAL with portable values, strict row decoding, positional parameter
  binding, execution and transaction protocols, and explicit database capabilities.
- Portable SQL ASTs and dialect-aware rendering for `SELECT`, `COUNT`, `INSERT`, `UPDATE`,
  `DELETE`, and `CREATE TABLE`, including identifier quoting and deterministic bind ordering.
- PostgreSQL and SQLite adapters with normalized value conversion, affected-row reporting,
  transaction behavior, generated-key handling, and lifecycle management.
- Value-semantic entity mapping with validated field descriptors, one primary key, and explicit
  row hydration.
- Actor-isolated sessions with identity-map snapshots and revision tracking for safe concurrent
  reads and conservative invalidation around raw SQL.
- Closure-scoped units of work with eager insert, update, and delete operations; local snapshot
  overlays; rollback-only failure handling; and promotion only after a successful commit.
- Typed single-table queries with composable predicates, ordering, pagination, and `find`,
  `fetch`, `first`, and `count` terminals.
- Positional raw SQL execution and detached raw entity hydration for operations outside the typed
  query surface.
- Shared SQLite and live PostgreSQL conformance suites covering DBAL behavior, generated SQL,
  ORM CRUD, queries, transaction commit, and rollback.
- A Swift 6.0 GitHub Actions workflow that builds with strict dependency-import checks, runs the
  full database matrix, and builds DocC archives with warnings treated as errors.
- A complete quick start, public API documentation, architecture notes, and an MIT license.

### Compatibility

- Swift 6.0 or newer.
- macOS 13 or newer when building on macOS.
- PostgreSQL through PerunPGSQL 0.3.x and SQLite through PerunSQLite 0.2.x.

### Known limitations

- Queries are single-table and hydrate complete entities; joins, relationships, projections, and
  aggregates other than `count` are not included.
- Exactly one non-optional primary key is supported. Generated primary keys must be `Int64`.
- Migrations, schema introspection, composite keys, lazy loading, lifecycle hooks, model macros,
  and nested units of work are deferred beyond 0.1.
- SQLite does not advertise `RETURNING` support in 0.1. Generated integer keys use the driver's
  last-inserted-row-ID path followed by a lookup in the same transaction.

[0.2.1]: https://github.com/tavvet/perun-orm/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/tavvet/perun-orm/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/tavvet/perun-orm/releases/tag/0.1.0
