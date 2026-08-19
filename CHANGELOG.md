# Changelog

All notable changes to PerunORM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/tavvet/perun-orm/releases/tag/0.1.0
