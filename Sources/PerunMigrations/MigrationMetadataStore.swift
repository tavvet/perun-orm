import PerunDBAL

private struct MigrationMetadataTimestamp: SQLValueConvertible {
    static let columnType: ColumnType = .timestamp
    static let isNullable = false

    let value: SQLTimestamp

    var sqlValue: SQLValue {
        .date(value)
    }

    init(sqlValue: SQLValue) throws {
        try sqlValue.validateForPortableBinding()
        guard case let .date(value) = sqlValue else {
            throw SQLValueConversionError.typeMismatch(
                expected: .timestamp,
                actual: sqlValue
            )
        }
        self.value = value
    }
}

struct MigrationMetadataRow: Sendable, Equatable {
    let reference: MigrationReference
    let appliedAt: SQLTimestamp
}

struct MigrationMetadataSnapshot: Sendable, Equatable {
    let rows: [MigrationMetadataRow]

    var references: [MigrationReference] {
        rows.map(\.reference)
    }
}

struct MigrationMetadataStore: Sendable {
    static let positionColumn = "position"
    static let idColumn = "id"
    static let revisionColumn = "revision"
    static let appliedAtColumn = "applied_at"

    let tableName: String
    let renderer: SQLRenderer

    init(tableName: String, dialect: any SQLDialect) {
        self.tableName = tableName
        renderer = SQLRenderer(dialect: dialect)
    }

    func createIfNeeded(using transaction: any Transaction) async throws {
        let statement = try renderer.render(
            SQLCreateTable(
                table: tableName,
                columns: [
                    SQLColumnDefinition(
                        name: Self.positionColumn,
                        type: .int64,
                        role: .primaryKey(generated: false)
                    ),
                    SQLColumnDefinition(
                        name: Self.idColumn,
                        type: .text,
                        unique: true
                    ),
                    SQLColumnDefinition(
                        name: Self.revisionColumn,
                        type: .int64
                    ),
                    SQLColumnDefinition(
                        name: Self.appliedAtColumn,
                        type: .timestamp
                    ),
                ],
                ifNotExists: true
            )
        )
        _ = try await transaction.execute(statement.sql, statement.parameters)
    }

    func readSnapshot(using transaction: any Transaction) async throws
        -> MigrationMetadataSnapshot
    {
        let statement = try renderer.render(
            SQLSelect(
                table: tableName,
                columns: [
                    Self.positionColumn,
                    Self.idColumn,
                    Self.revisionColumn,
                    Self.appliedAtColumn,
                ],
                orderings: [
                    SQLOrdering(column: Self.positionColumn),
                ]
            )
        )
        let result = try await transaction.execute(statement.sql, statement.parameters)
        return try decodeSnapshot(result.rows)
    }

    func insert(
        reference: MigrationReference,
        appliedAt: SQLTimestamp,
        using transaction: any Transaction
    ) async throws -> MigrationMetadataRow {
        try SQLValue.date(appliedAt).validateForPortableBinding()
        let statement = try renderer.render(
            SQLInsert(
                table: tableName,
                values: [
                    SQLColumnValue(
                        column: Self.positionColumn,
                        value: .int(reference.position)
                    ),
                    SQLColumnValue(
                        column: Self.idColumn,
                        value: .text(reference.id)
                    ),
                    SQLColumnValue(
                        column: Self.revisionColumn,
                        value: .int(reference.revision)
                    ),
                    SQLColumnValue(
                        column: Self.appliedAtColumn,
                        value: .date(appliedAt)
                    ),
                ]
            )
        )
        _ = try await transaction.execute(statement.sql, statement.parameters)
        return MigrationMetadataRow(reference: reference, appliedAt: appliedAt)
    }

    func decodeSnapshot(_ rows: [any Row]) throws -> MigrationMetadataSnapshot {
        var decodedRows: [MigrationMetadataRow] = []
        decodedRows.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            let rowOrdinal = Int64(index) + 1
            let position: Int64 = try decode(
                Self.positionColumn,
                from: row,
                rowOrdinal: rowOrdinal
            )
            guard position > 0 else {
                throw invalidValue(
                    column: Self.positionColumn,
                    rowOrdinal: rowOrdinal
                )
            }

            let id: String = try decode(
                Self.idColumn,
                from: row,
                rowOrdinal: rowOrdinal
            )
            guard MigrationValidation.isValidMigrationID(id) else {
                throw invalidValue(
                    column: Self.idColumn,
                    rowOrdinal: rowOrdinal
                )
            }

            let revision: Int64 = try decode(
                Self.revisionColumn,
                from: row,
                rowOrdinal: rowOrdinal
            )
            guard revision > 0 else {
                throw invalidValue(
                    column: Self.revisionColumn,
                    rowOrdinal: rowOrdinal
                )
            }

            let appliedAt: MigrationMetadataTimestamp = try decode(
                Self.appliedAtColumn,
                from: row,
                rowOrdinal: rowOrdinal
            )

            decodedRows.append(
                MigrationMetadataRow(
                    reference: MigrationReference(
                        position: position,
                        id: id,
                        revision: revision
                    ),
                    appliedAt: appliedAt.value
                )
            )
        }

        return MigrationMetadataSnapshot(rows: decodedRows)
    }

    private func decode<T: SQLValueConvertible>(
        _ column: String,
        from row: any Row,
        rowOrdinal: Int64
    ) throws -> T {
        do {
            return try row.decode(column, as: T.self)
        } catch {
            throw MigrationHistoryError.malformedRow(
                rowOrdinal: rowOrdinal,
                column: column,
                reason: .unreadable
            )
        }
    }

    private func invalidValue(
        column: String,
        rowOrdinal: Int64
    ) -> MigrationHistoryError {
        .malformedRow(
            rowOrdinal: rowOrdinal,
            column: column,
            reason: .invalidValue
        )
    }
}

extension Migrator {
    /// Creates the tracking table if needed and returns applied and pending plan references.
    ///
    /// Status reads history only after acquiring the same database-wide exclusive transaction
    /// used by migration execution. It validates the persisted rows as an exact local-plan prefix
    /// and never invokes migration bodies.
    public func status() async throws -> MigrationStatus {
        try Task.checkCancellation()
        let database = self.database
        let plan = self.plan
        let store = MigrationMetadataStore(
            tableName: plan.trackingTableName,
            dialect: database.dialect
        )

        return try await database.withExclusiveTransaction(lockKey: plan.lockKey) { transaction in
            try await store.createIfNeeded(using: transaction)
            let snapshot = try await store.readSnapshot(using: transaction)
            let status = try plan.status(applied: snapshot.references)
            try Task.checkCancellation()
            return status
        }
    }
}
