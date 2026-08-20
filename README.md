# PerunORM

PerunORM is a small, async Swift ORM and database abstraction layer for PostgreSQL and SQLite.
It keeps the SQL core backend-neutral while exposing explicit adapters for both databases.

The 0.1 API is intentionally narrow: value-semantic entities, one primary key, typed
single-table queries, eager CRUD inside a closure-scoped unit of work, and raw SQL escape
hatches when the typed surface is not enough.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer when building on macOS
- PostgreSQL or SQLite

## Package products

| Product | Purpose |
| --- | --- |
| `PerunDBAL` | Backend-neutral values, rows, SQL AST, rendering, and execution protocols |
| `PerunDBALPostgres` | PostgreSQL database façade and dialect |
| `PerunDBALSQLite` | SQLite database façade and dialect |
| `PerunMigrations` | Ordered forward-only migration planning, under development for 0.2 |
| `PerunORM` | Entity mapping, sessions, typed queries, and unit-of-work CRUD |

## Installation

Add PerunORM to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/tavvet/perun-orm.git",
        from: "0.1.0"
    ),
]
```

Depend on the neutral DBAL, the ORM, and the adapter used by your target:

```swift
.executableTarget(
    name: "App",
    dependencies: [
        .product(name: "PerunDBAL", package: "perun-orm"),
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

let database: any Database = SQLiteDatabase(
    configuration: .file("perun.sqlite"),
    maxConnections: 1
)
```

For an ephemeral SQLite database, use `.memory()` with `maxConnections: 1`. A plain
`:memory:` database is private to one connection.

PostgreSQL:

```swift
import PerunDBALPostgres

let database: any Database = PostgresDatabase(
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

### 3. Create the schema

PerunORM 0.1 does not run migrations or create tables automatically. This DDL works for the
assigned-key `Todo` mapping on both supported databases:

```swift
_ = try await database.execute(
    """
    CREATE TABLE IF NOT EXISTS "todos" (
        "id" BIGINT PRIMARY KEY,
        "title" TEXT NOT NULL,
        "is_done" BOOLEAN NOT NULL
    )
    """,
    []
)
```

### 4. Insert and update in a unit of work

Writes are eager inside `withUnitOfWork`, but their snapshots reach the session identity map
only after a successful commit.

```swift
let session = Session(database: database)

let inserted = try await session.withUnitOfWork { unitOfWork in
    try await unitOfWork.insert(
        Todo(id: 1, title: "Ship PerunORM 0.1", isDone: false)
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

## Important 0.1 semantics

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

PerunORM 0.1 does not yet include relationships, joins, migrations, schema introspection,
composite primary keys, lazy loading, lifecycle hooks, or model macros. See the
[0.1 design draft](docs/0.1-design-draft.md) for the complete rationale and deferred scope.

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
