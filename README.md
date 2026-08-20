# PerunORM

PerunORM is a small, async Swift ORM, database abstraction layer, and migration runner for
PostgreSQL and SQLite. It keeps the SQL core backend-neutral while exposing explicit adapters for
both databases.

The 0.2 API adds atomic forward-only migrations while keeping the ORM intentionally narrow:
value-semantic entities, one primary key, typed single-table queries, eager CRUD inside a
closure-scoped unit of work, and raw SQL escape hatches when the typed surface is not enough.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer when building on macOS
- PostgreSQL or SQLite
- On Debian/Ubuntu Linux, `libssl-dev` for PostgreSQL, `libsqlite3-dev` for SQLite, and
  `pkg-config`

## Package products

| Product | Purpose |
| --- | --- |
| `PerunDBAL` | Backend-neutral values, rows, SQL AST, rendering, and execution protocols |
| `PerunDBALPostgres` | PostgreSQL database façade and dialect |
| `PerunDBALSQLite` | SQLite database façade and dialect |
| `PerunMigrations` | Atomic forward-only migrations, history validation, and status |
| `PerunORM` | Entity mapping, sessions, typed queries, and unit-of-work CRUD |

## Installation

Add PerunORM to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/tavvet/perun-orm.git",
        from: "0.2.0"
    ),
]
```

Depend on the neutral DBAL, migrations, the ORM, and the adapter used by your target:

```swift
.executableTarget(
    name: "App",
    dependencies: [
        .product(name: "PerunDBAL", package: "perun-orm"),
        .product(name: "PerunMigrations", package: "perun-orm"),
        .product(name: "PerunORM", package: "perun-orm"),
        .product(name: "PerunDBALSQLite", package: "perun-orm"),
        // Or: .product(name: "PerunDBALPostgres", package: "perun-orm"),
    ]
)
```

## Quick start

### 1. Define an entity

Entities are `Sendable` value types. Their field descriptors are the single source of mapping
metadata, and `init(row:)` defines hydration.

```swift
import PerunDBAL
import PerunORM

struct Todo: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let title: String
    let isDone: Bool

    static let tableName = "todos"

    static var fields: [FieldDescriptor<Todo>] {
        [
            FieldDescriptor(
                \Todo.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\Todo.title, column: "title"),
            FieldDescriptor(\Todo.isDone, column: "is_done"),
        ]
    }

    init(id: Int64, title: String, isDone: Bool) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        title = try row.decode("title", as: String.self)
        isDone = try row.decode("is_done", as: Bool.self)
    }
}
```

### 2. Choose a database

SQLite:

```swift
import PerunDBALSQLite

let database: any ExclusiveTransactionDatabase = SQLiteDatabase(
    configuration: .file("perun.sqlite"),
    maxConnections: 1
)
```

For an ephemeral SQLite database, use `.memory()` with `maxConnections: 1`. A plain
`:memory:` database is private to one connection.

PostgreSQL:

```swift
import PerunDBALPostgres

let database: any ExclusiveTransactionDatabase = PostgresDatabase(
    configuration: .init(
        host: "localhost",
        port: 5_432,
        user: "perun",
        database: "perun",
        password: "perun",
        tlsMode: .disable // Local development only; production defaults to .verifyFull.
    ),
    maxConnections: 4
)
```

### 3. Run migrations

`Migrator` receives the complete ordered plan on every launch. The first run applies the pending
suffix in one exclusive transaction; later runs validate the persisted prefix and become no-ops
until a new migration is appended.

```swift
import PerunMigrations

let migrations = [
    Migration(id: "001_create_todos") { context in
        let statement = try context.renderer.render(
            SQLCreateTable(
                table: Todo.tableName,
                columns: [
                    SQLColumnDefinition(
                        name: "id",
                        type: .int64,
                        role: .primaryKey(generated: false)
                    ),
                    SQLColumnDefinition(name: "title", type: .text),
                    SQLColumnDefinition(name: "is_done", type: .boolean),
                ]
            )
        )
        _ = try await context.execute(statement.sql, statement.parameters)
    },
    Migration(id: "002_seed_todos") { context in
        let statement = try context.renderer.render(
            SQLInsert(
                table: Todo.tableName,
                values: [
                    SQLColumnValue(column: "id", value: .int(0)),
                    SQLColumnValue(column: "title", value: .text("Read the migration guide")),
                    SQLColumnValue(column: "is_done", value: .bool(false)),
                ]
            )
        )
        _ = try await context.execute(statement.sql, statement.parameters)
    },
]

let migrator = try Migrator(database: database, migrations: migrations)
let before = try await migrator.status() // applied: [], pending: [001, 002]
let firstReport = try await migrator.migrate() // applied: [001, 002]
let restartReport = try await migrator.migrate() // applied: []
```

For the next release, preserve the complete existing prefix and append a new migration. Only the
new suffix runs:

```swift
let nextReleaseMigrations = migrations + [
    Migration(id: "003_complete_seed_todo") { context in
        let p1 = context.dialect.placeholder(at: 1)
        let p2 = context.dialect.placeholder(at: 2)
        _ = try await context.execute(
            "UPDATE \"todos\" SET \"is_done\" = \(p1) WHERE \"id\" = \(p2)",
            [.bool(true), .int(0)]
        )
    },
]

let nextMigrator = try Migrator(database: database, migrations: nextReleaseMigrations)
let appendReport = try await nextMigrator.migrate() // applied: [003]
```

Migration identifiers and revisions are persisted API. Never reorder, remove, rename, or edit an
applied migration; append a new one instead. A history mismatch is reported before any pending body
starts.

The complete pending suffix and its tracking rows commit or roll back together. Migration bodies
run sequentially and must finish all work before returning. Do not retain `MigrationContext`, start
overlapping operations, or issue `BEGIN`, `COMMIT`, `ROLLBACK`, savepoint commands, or SQL batches.
If an executor error is caught inside a body, the context remains rollback-only and `migrate()`
still fails. External network, filesystem, sequence, and other nontransactional effects are outside
the rollback guarantee, so keep bodies retry-safe.

Run migrations before serving application traffic, or in a maintenance window. Ordinary
application SQL does not participate in the migration lock. If commit acknowledgement is lost,
call `status()` or `migrate()` again and let tracking history determine whether the batch committed.

### 4. Insert and update in a unit of work

Writes are eager inside `withUnitOfWork`, but their snapshots reach the session identity map
only after a successful commit.

```swift
let session = Session(database: database)

let inserted = try await session.withUnitOfWork { unitOfWork in
    try await unitOfWork.insert(
        Todo(id: 1, title: "Ship PerunORM 0.2", isDone: false)
    )
}

let completed = Todo(
    id: inserted.id,
    title: inserted.title,
    isDone: true
)

let updated = try await session.withUnitOfWork { unitOfWork in
    try await unitOfWork.update(completed, from: inserted)
}
```

`update(_:from:)` and `delete(_:)` require the latest managed snapshot returned by this
session. Detached or stale values are rejected before SQL execution.

### 5. Query entities

```swift
let isDone = try Predicate<Todo>.eq(\Todo.isDone, true)
let query = try Query(Todo.self)
    .where(isDone)
    .order(by: \Todo.id)
    .limit(20)

let todos = try await session.fetch(query)
let first = try await session.first(query)
let count = try await session.count(query)
let byID = try await session.find(Todo.self, updated.id)
```

Predicates support `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `like`, `isNull`, `in`, and
`and`/`or`/`not` composition. Query values and pagination are always bound parameters;
identifiers are quoted by the selected dialect.

### 6. Use raw SQL

Use `execute` for arbitrary positional SQL:

```swift
let p1 = database.dialect.placeholder(at: 1)
let p2 = database.dialect.placeholder(at: 2)
_ = try await session.execute(
    "UPDATE \"todos\" SET \"is_done\" = \(p1) WHERE \"id\" = \(p2)",
    [.bool(true), .int(1)]
)
```

Raw placeholders belong to the selected backend (`?` for SQLite and `$1`, `$2`, ... for
PostgreSQL). To build a portable raw statement, ask the dialect for each placeholder:

```swift
let rawP1 = database.dialect.placeholder(at: 1)
let rawTodos = try await session.fetch(
    Todo.self,
    sql: """
        SELECT "id", "title", "is_done"
        FROM "todos"
        WHERE "is_done" = \(rawP1)
        """,
    params: [.bool(true)]
)
```

Raw SQL has unknown read/write effects. A direct raw operation invalidates the session identity
map, and raw-hydrated entities remain detached. Inside a unit of work, raw SQL clears the prior
overlay and disables base-cache hits; transaction-control statements are rejected.

### 7. Delete an entity

```swift
if let current = try await session.find(Todo.self, updated.id) {
    try await session.withUnitOfWork { unitOfWork in
        try await unitOfWork.delete(current)
    }
}
```

The typed lookup is intentional: the preceding raw operations invalidated the previously
managed `updated` snapshot.

### 8. Shut down the database

The composition root owns the pool lifecycle. Shut the database down after all work has
finished:

```swift
await database.shutdown()
```

## Important semantics

### Migrations

- Every run supplies the complete canonical plan. Persisted history must be its exact prefix.
- The whole pending suffix is one atomic transaction, not one transaction per migration.
- PostgreSQL uses a database-wide advisory transaction lock. SQLite uses `BEGIN IMMEDIATE` and
  intentionally serializes all writers more strongly.
- Different tracking table names do not permit concurrent migration bodies.
- `MigrationReport.applied` contains only migrations committed by that call. An empty report means
  the database was already current.
- `MigrationStatus` is read under the same exclusive transaction used by `migrate()` and never
  invokes migration bodies.

### Sessions and units of work

- `Session` and `UnitOfWork` are actors.
- Direct session operations may overlap; identity revisions prevent a late read from restoring
  a snapshot invalidated by raw SQL.
- A unit of work exclusively owns its session's database access while active. Use the
  `UnitOfWork` passed to the closure. Starting a unit of work while a direct session operation is
  in flight, or invoking a direct session operation while a unit of work is active, fails with
  `SessionError.sessionBusy`.
- Unit-of-work operations are strictly serial. An overlapping call fails with
  `SessionError.unitOfWorkBusy`.
- Any transaction executor failure makes the unit of work rollback-only.
- A raw hydration failure after execution also forces rollback because the SQL may have been DML
  with `RETURNING`.
- Entities and directly mapped fields must have value semantics.
- One non-optional primary key is supported. Generated primary keys must be `Int64`.

## Current scope

PerunORM 0.2 does not include relationships, joins, schema introspection, down migrations,
nontransactional migration steps, composite primary keys, lazy loading, lifecycle hooks, or model
macros. See the [0.2 design draft](docs/0.2-design-draft.md) for the migration contract and the
[0.1 design draft](docs/0.1-design-draft.md) for the ORM architecture.

## Testing

Run the default suite. SQLite integration runs locally; live PostgreSQL tests stay disabled:

```sh
swift test
```

Enable the live PostgreSQL conformance suite with environment variables:

```sh
PERUN_PGSQL_INTEGRATION=1 \
PGHOST=localhost \
PGPORT=5432 \
PGUSER=perun \
PGDATABASE=perun \
PGPASSWORD=perun \
PGSSLMODE=disable \
swift test
```

The PostgreSQL suite creates and drops its own test tables in the selected database.
GitHub Actions runs the strict build, consumer smoke, and SQLite/PostgreSQL suite on macOS and
Linux. DocC remains in the macOS job because the workflow uses Xcode's `docc` executable.
