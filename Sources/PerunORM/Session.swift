import Foundation
import PerunDBAL

public enum SessionError: Error, Sendable, Equatable {
    case sessionBusy
    case unitOfWorkBusy
    case unitOfWorkClosed
    case unitOfWorkRollbackOnly
    case transactionControlNotAllowed(command: String)
}

/// ORM-level invariant failures detected after schema validation or row execution.
public enum ORMError: Error, Sendable, Equatable {
    case identityMapTypeMismatch(table: String, primaryKey: SQLValue)
    case multipleRowsForPrimaryKey(table: String, primaryKey: SQLValue)
    case hydratedPrimaryKeyMismatch(table: String, expected: SQLValue, actual: SQLValue)
    case generatedPrimaryKeyRetrievalUnsupported(table: String)
    case unexpectedInsertAffectedRowCount(table: String, actual: Int?)
    case unexpectedInsertResultRowCount(table: String, actual: Int)
    case generatedPrimaryKeyUnavailable(table: String)
    case insertedRowLookupCount(table: String, primaryKey: SQLValue, actual: Int)
}

fileprivate struct EntityKey: Sendable, Hashable {
    let type: ObjectIdentifier
    let primaryKey: SQLValue
}

fileprivate struct EntityFindPlan<E: Entity>: Sendable {
    let tableName: String
    let statement: SQLSelect
    let cachedEntity: E?
}

fileprivate struct EntityInsertPlan: Sendable {
    let tableName: String
    let statement: SQLInsert
    let primaryKey: SQLValue
    let primaryKeyIsGenerated: Bool
}

fileprivate struct UnitOfWorkChanges: Sendable {
    let invalidatesIdentity: Bool
    let snapshots: [EntityKey: any Entity]
}

private struct UnitOfWorkOutcome<Value: Sendable>: Sendable {
    let value: Value
    let changes: UnitOfWorkChanges
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
        let dialect = database.dialect
        activeUnitOfWork = token
        defer {
            precondition(activeUnitOfWork == token)
            activeUnitOfWork = nil
        }

        let outcome = try await database.withTransaction { transaction in
            let unitOfWork = UnitOfWork(
                transaction: transaction,
                dialect: dialect,
                session: self,
                token: token
            )
            do {
                let value = try await body(unitOfWork)
                let changes = try await unitOfWork.close()
                return UnitOfWorkOutcome(value: value, changes: changes)
            } catch {
                _ = try? await unitOfWork.close()
                throw error
            }
        }

        if outcome.changes.invalidatesIdentity {
            identity.removeAll(keepingCapacity: true)
        }
        for (key, entity) in outcome.changes.snapshots {
            identity[key] = entity
        }
        return outcome.value
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

    fileprivate func unitOfWorkFindPlan<E: Entity>(
        for type: E.Type,
        primaryKey: E.PK,
        useCachedEntity: Bool,
        token: UUID
    ) throws -> EntityFindPlan<E> {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: type)
        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        let cachedEntity: E?
        if useCachedEntity, let cached = identity[key] {
            guard let entity = cached as? E else {
                throw ORMError.identityMapTypeMismatch(
                    table: schema.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            cachedEntity = entity
        } else {
            cachedEntity = nil
        }
        return EntityFindPlan(
            tableName: schema.tableName,
            statement: schema.findStatement(primaryKey: primaryKey),
            cachedEntity: cachedEntity
        )
    }

    fileprivate func unitOfWorkInsertPlan<E: Entity>(
        for entity: E,
        returning: Bool,
        token: UUID
    ) throws -> EntityInsertPlan {
        try validateUnitOfWork(token)
        let schema = try validatedSchema(for: E.self)
        return EntityInsertPlan(
            tableName: schema.tableName,
            statement: schema.insertStatement(entity, returning: returning),
            primaryKey: schema.primaryKey.read(from: entity),
            primaryKeyIsGenerated: schema.primaryKeyIsGenerated
        )
    }

    fileprivate func unitOfWorkPrimaryKey<E: Entity>(
        of entity: E,
        token: UUID
    ) throws -> SQLValue {
        try validateUnitOfWork(token)
        return try validatedSchema(for: E.self).primaryKey.read(from: entity)
    }

    fileprivate func invalidateIdentityForUnitOfWork(token: UUID) {
        precondition(activeUnitOfWork == token)
        identity.removeAll(keepingCapacity: true)
    }

    fileprivate func invalidateIdentityKeyForUnitOfWork(_ key: EntityKey, token: UUID) {
        precondition(activeUnitOfWork == token)
        identity.removeValue(forKey: key)
    }

    private func validateUnitOfWork(_ token: UUID) throws {
        guard activeUnitOfWork == token else {
            throw SessionError.unitOfWorkClosed
        }
    }
}

/// The scoped transactional executor. Its snapshots reach the session only after commit.
public actor UnitOfWork {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private let transaction: any Transaction
    private let dialect: any SQLDialect
    private let session: Session
    private let token: UUID
    private var lifecycle = Lifecycle.open
    private var inFlightOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var overlay: [EntityKey: any Entity] = [:]
    private var rollbackOnly = false
    private var invalidatesSessionIdentity = false

    init(
        transaction: any Transaction,
        dialect: any SQLDialect,
        session: Session,
        token: UUID
    ) {
        self.transaction = transaction
        self.dialect = dialect
        self.session = session
        self.token = token
    }

    /// Executes one raw statement. Success invalidates prior ORM snapshots conservatively;
    /// transaction-control statements are rejected and make this unit of work rollback-only.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        try beginOperation()
        defer { endOperation() }

        if let command = transactionControlCommand(in: sql) {
            rollbackOnly = true
            throw SessionError.transactionControlNotAllowed(command: command)
        }

        let result = try await executeTransaction(sql, parameters)
        let shouldInvalidateBaseIdentity = !invalidatesSessionIdentity
        invalidatesSessionIdentity = true
        overlay.removeAll(keepingCapacity: true)
        if shouldInvalidateBaseIdentity {
            // Commit may succeed before its caller observes cancellation or a timeout.
            await session.invalidateIdentityForUnitOfWork(token: token)
        }
        return result
    }

    /// Returns the transactional snapshot for a primary key, including local inserts.
    public func find<E: Entity>(_ type: E.Type, _ primaryKey: E.PK) async throws -> E? {
        try beginOperation()
        defer { endOperation() }

        let primaryKeyValue = primaryKey.sqlValue
        let key = EntityKey(type: ObjectIdentifier(type), primaryKey: primaryKeyValue)
        let plan = try await session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            useCachedEntity: !invalidatesSessionIdentity,
            token: token
        )
        if let cached = overlay[key] {
            guard let entity = cached as? E else {
                throw ORMError.identityMapTypeMismatch(
                    table: plan.tableName,
                    primaryKey: primaryKeyValue
                )
            }
            return entity
        }
        if let cached = plan.cachedEntity {
            return cached
        }

        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        guard result.rows.count <= 1 else {
            throw ORMError.multipleRowsForPrimaryKey(
                table: plan.tableName,
                primaryKey: primaryKeyValue
            )
        }
        guard let row = result.rows.first else { return nil }

        let entity = try E(row: row)
        let hydratedPrimaryKey = try await session.unitOfWorkPrimaryKey(
            of: entity,
            token: token
        )
        guard hydratedPrimaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: plan.tableName,
                expected: primaryKeyValue,
                actual: hydratedPrimaryKey
            )
        }
        overlay[key] = entity
        return entity
    }

    /// Inserts one entity eagerly and returns the snapshot carrying its final primary key.
    public func insert<E: Entity>(_ entity: E) async throws -> E {
        try beginOperation()
        defer { endOperation() }

        var writeCompleted = false
        do {
            let usesReturning = dialect.capabilities.contains(.returning)
            let plan = try await session.unitOfWorkInsertPlan(
                for: entity,
                returning: usesReturning,
                token: token
            )
            let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)

            if usesReturning {
                let result = try await executeTransaction(rendered.sql, rendered.parameters)
                writeCompleted = true
                try validateKnownAffectedRowCount(result.rowsAffected, table: plan.tableName)
                guard result.rows.count == 1, let row = result.rows.first else {
                    throw ORMError.unexpectedInsertResultRowCount(
                        table: plan.tableName,
                        actual: result.rows.count
                    )
                }
                let inserted = try E(row: row)
                return try await storeInserted(inserted, plan: plan)
            }

            if plan.primaryKeyIsGenerated {
                guard dialect.capabilities.contains(.lastInsertRowID) else {
                    throw ORMError.generatedPrimaryKeyRetrievalUnsupported(table: plan.tableName)
                }
                let result = try await executeTransaction(
                    rendered.sql,
                    rendered.parameters,
                    intent: .generatedRowIDInsert
                )
                writeCompleted = true
                guard result.rowsAffected == 1 else {
                    throw ORMError.unexpectedInsertAffectedRowCount(
                        table: plan.tableName,
                        actual: result.rowsAffected
                    )
                }
                guard let rowID = result.lastInsertRowID else {
                    throw ORMError.generatedPrimaryKeyUnavailable(table: plan.tableName)
                }
                let primaryKey = try E.PK(sqlValue: .int(rowID))
                return try await loadInserted(
                    E.self,
                    primaryKey: primaryKey,
                    table: plan.tableName
                )
            }

            let result = try await executeTransaction(
                rendered.sql,
                rendered.parameters
            )
            writeCompleted = true
            try validateKnownAffectedRowCount(result.rowsAffected, table: plan.tableName)
            return await stageInserted(entity, primaryKey: plan.primaryKey)
        } catch {
            if writeCompleted {
                rollbackOnly = true
            }
            throw error
        }
    }

    fileprivate func close() async throws -> UnitOfWorkChanges {
        switch lifecycle {
        case .open:
            lifecycle = .closing
            if inFlightOperations == 0 {
                finishClosing()
            }
        case .closing:
            break
        case .closed:
            guard !rollbackOnly else {
                throw SessionError.unitOfWorkRollbackOnly
            }
            return changes
        }

        if lifecycle != .closed {
            await withCheckedContinuation { continuation in
                if lifecycle == .closed {
                    continuation.resume()
                } else {
                    closeWaiters.append(continuation)
                }
            }
        }
        guard !rollbackOnly else {
            throw SessionError.unitOfWorkRollbackOnly
        }
        return changes
    }

    private func beginOperation() throws {
        guard lifecycle == .open else {
            throw SessionError.unitOfWorkClosed
        }
        guard !rollbackOnly else {
            throw SessionError.unitOfWorkRollbackOnly
        }
        guard inFlightOperations == 0 else {
            throw SessionError.unitOfWorkBusy
        }
        inFlightOperations += 1
    }

    private func endOperation() {
        precondition(inFlightOperations > 0)
        inFlightOperations -= 1
        if lifecycle == .closing, inFlightOperations == 0 {
            finishClosing()
        }
    }

    private func executeTransaction(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent = .arbitrary
    ) async throws -> ExecResult {
        do {
            return try await transaction.execute(sql, parameters, intent: intent)
        } catch {
            rollbackOnly = true
            throw error
        }
    }

    private func validateKnownAffectedRowCount(_ actual: Int?, table: String) throws {
        if let actual, actual != 1 {
            throw ORMError.unexpectedInsertAffectedRowCount(table: table, actual: actual)
        }
    }

    private var changes: UnitOfWorkChanges {
        UnitOfWorkChanges(
            invalidatesIdentity: invalidatesSessionIdentity,
            snapshots: overlay
        )
    }

    private func storeInserted<E: Entity>(
        _ inserted: E,
        plan: EntityInsertPlan
    ) async throws -> E {
        let primaryKey = try await session.unitOfWorkPrimaryKey(of: inserted, token: token)
        if !plan.primaryKeyIsGenerated, primaryKey != plan.primaryKey {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: plan.tableName,
                expected: plan.primaryKey,
                actual: primaryKey
            )
        }
        return await stageInserted(inserted, primaryKey: primaryKey)
    }

    private func loadInserted<E: Entity>(
        _ type: E.Type,
        primaryKey: E.PK,
        table: String
    ) async throws -> E {
        let primaryKeyValue = primaryKey.sqlValue
        let plan = try await session.unitOfWorkFindPlan(
            for: type,
            primaryKey: primaryKey,
            useCachedEntity: false,
            token: token
        )
        let rendered = try SQLRenderer(dialect: dialect).render(plan.statement)
        let result = try await executeTransaction(rendered.sql, rendered.parameters)
        guard result.rows.count == 1, let row = result.rows.first else {
            throw ORMError.insertedRowLookupCount(
                table: table,
                primaryKey: primaryKeyValue,
                actual: result.rows.count
            )
        }
        let inserted = try E(row: row)
        let hydratedPrimaryKey = try await session.unitOfWorkPrimaryKey(
            of: inserted,
            token: token
        )
        guard hydratedPrimaryKey == primaryKeyValue else {
            throw ORMError.hydratedPrimaryKeyMismatch(
                table: table,
                expected: primaryKeyValue,
                actual: hydratedPrimaryKey
            )
        }
        return await stageInserted(inserted, primaryKey: primaryKeyValue)
    }

    private func stageInserted<E: Entity>(
        _ inserted: E,
        primaryKey: SQLValue
    ) async -> E {
        let key = EntityKey(type: ObjectIdentifier(E.self), primaryKey: primaryKey)
        overlay[key] = inserted
        // COMMIT may succeed before its caller observes cancellation or a timeout.
        await session.invalidateIdentityKeyForUnitOfWork(key, token: token)
        return inserted
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

private func transactionControlCommand(in sql: String) -> String? {
    let keywords = leadingSQLKeywords(in: sql, limit: 2)
    guard let first = keywords.first else { return nil }

    switch first {
    case "BEGIN", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE":
        return first
    case "START", "PREPARE", "SET":
        guard keywords.count == 2, keywords[1] == "TRANSACTION" else { return nil }
        return "\(first) TRANSACTION"
    default:
        return nil
    }
}

private func leadingSQLKeywords(in sql: String, limit: Int) -> [String] {
    let bytes = Array(sql.utf8)
    var index = 0
    var keywords: [String] = []

    while keywords.count < limit {
        skipSQLTrivia(bytes, index: &index)
        let start = index
        while index < bytes.count, isSQLIdentifierByte(bytes[index]) {
            index += 1
        }
        guard start < index else { break }
        keywords.append(String(decoding: bytes[start ..< index], as: UTF8.self).uppercased())
    }
    return keywords
}

private func skipSQLTrivia(_ bytes: [UInt8], index: inout Int) {
    while index < bytes.count {
        if isSQLWhitespace(bytes[index]) || bytes[index] == UInt8(ascii: ";") {
            index += 1
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "-"),
           bytes[index + 1] == UInt8(ascii: "-") {
            index += 2
            while index < bytes.count,
                  bytes[index] != UInt8(ascii: "\n"),
                  bytes[index] != UInt8(ascii: "\r") {
                index += 1
            }
            continue
        }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "/"),
           bytes[index + 1] == UInt8(ascii: "*") {
            index += 2
            var depth = 1
            while index < bytes.count, depth > 0 {
                if index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "/"),
                   bytes[index + 1] == UInt8(ascii: "*") {
                    depth += 1
                    index += 2
                } else if index + 1 < bytes.count,
                          bytes[index] == UInt8(ascii: "*"),
                          bytes[index + 1] == UInt8(ascii: "/") {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            continue
        }
        break
    }
}

private func isSQLWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || (UInt8(ascii: "\t") ... UInt8(ascii: "\r")).contains(byte)
}

private func isSQLIdentifierByte(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "_")
        || byte == UInt8(ascii: "$")
}
