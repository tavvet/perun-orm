import Foundation
import PerunDBAL

public enum SessionError: Error, Sendable, Equatable {
    case sessionBusy
    case unitOfWorkBusy
    case unitOfWorkClosed
}

/// ORM-level invariant failures detected after schema validation or row execution.
public enum ORMError: Error, Sendable, Equatable {
    case identityMapTypeMismatch(table: String, primaryKey: SQLValue)
    case multipleRowsForPrimaryKey(table: String, primaryKey: SQLValue)
    case hydratedPrimaryKeyMismatch(table: String, expected: SQLValue, actual: SQLValue)
}

private struct EntityKey: Sendable, Hashable {
    let type: ObjectIdentifier
    let primaryKey: SQLValue
}

/// Actor-isolated ORM state. Database operations inside a transaction are exposed only by UoW.
public actor Session {
    private let database: any Database
    private var validatedSchemas: [ObjectIdentifier: Any] = [:]
    private var identity: [EntityKey: any Entity] = [:]
    private var activeUnitOfWork: UUID?
    private var activeDatabaseOperations = 0

    public init(database: any Database) {
        self.database = database
    }

    /// Raw positional SQL escape hatch outside a unit of work.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }
        return try await database.execute(sql, parameters)
    }

    /// Returns the session snapshot for a primary key, hydrating and caching it on a miss.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginDirectDatabaseOperation()
        defer { endDirectDatabaseOperation() }

        let schema = try validatedSchema(for: type)
        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        if let cached = identity[key] {
            guard let entity = cached as? E else {
                throw ORMError.identityMapTypeMismatch(
                    table: schema.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            return entity
        }

        let rendered = try SQLRenderer(dialect: database.dialect).render(
            schema.findStatement(primaryKey: primaryKey)
        )
        let result = try await database.execute(rendered.sql, rendered.parameters)
        guard result.rows.count <= 1 else {
            throw ORMError.multipleRowsForPrimaryKey(
                table: schema.tableName,
                primaryKey: primaryKeyValue
            )
        }
        guard let row = result.rows.first else { return nil }

        let entity = try E(row: row)
        let hydratedPrimaryKey = schema.primaryKey.read(from: entity)
        guard hydratedPrimaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: schema.tableName,
                expected: primaryKeyValue,
                actual: hydratedPrimaryKey
            )
        }
        identity[key] = entity
        return entity
    }

    public func withUnitOfWork<T: Sendable>(
        _ body: @Sendable (UnitOfWork) async throws -> T
    ) async throws -> T {
        guard activeUnitOfWork == nil, activeDatabaseOperations == 0 else {
            throw SessionError.sessionBusy
        }

        let token = UUID()
        activeUnitOfWork = token
        defer {
            precondition(activeUnitOfWork == token)
            activeUnitOfWork = nil
        }

        return try await database.withTransaction { transaction in
            let unitOfWork = UnitOfWork(transaction: transaction)
            do {
                let result = try await body(unitOfWork)
                await unitOfWork.close()
                return result
            } catch {
                await unitOfWork.close()
                throw error
            }
        }
    }

    private func beginDirectDatabaseOperation() throws {
        guard activeUnitOfWork == nil else {
            throw SessionError.sessionBusy
        }
        activeDatabaseOperations += 1
    }

    private func endDirectDatabaseOperation() {
        precondition(activeDatabaseOperations > 0)
        activeDatabaseOperations -= 1
    }

    private func validatedSchema<E: Entity>(for type: E.Type) throws -> EntitySchema<E> {
        let key = ObjectIdentifier(type)
        if let cached = validatedSchemas[key] {
            guard let schema = cached as? EntitySchema<E> else {
                preconditionFailure("entity type key resolved to a different validated schema")
            }
            return schema
        }

        let schema = try EntitySchema(type)
        validatedSchemas[key] = schema
        return schema
    }
}

/// The scoped transactional executor. Snapshot overlays are added with CRUD in the next slice.
public actor UnitOfWork {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private let transaction: any Transaction
    private var lifecycle = Lifecycle.open
    private var inFlightOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(transaction: any Transaction) {
        self.transaction = transaction
    }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        guard lifecycle == .open else {
            throw SessionError.unitOfWorkClosed
        }
        guard inFlightOperations == 0 else {
            throw SessionError.unitOfWorkBusy
        }
        inFlightOperations += 1
        defer {
            inFlightOperations -= 1
            if lifecycle == .closing, inFlightOperations == 0 {
                finishClosing()
            }
        }
        return try await transaction.execute(sql, parameters)
    }

    func close() async {
        switch lifecycle {
        case .open:
            lifecycle = .closing
            if inFlightOperations == 0 {
                finishClosing()
                return
            }
        case .closing:
            break
        case .closed:
            return
        }

        await withCheckedContinuation { continuation in
            if lifecycle == .closed {
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
            }
        }
    }

    private func finishClosing() {
        lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
