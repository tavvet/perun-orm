@testable import PerunMigrations
import PerunDBAL
import PerunDBALPostgres
import PerunDBALSQLite
import Testing

@Test
func metadataStoreRendersExactPostgresTrackingStatements() async throws {
    let calls = try await recordMetadataStoreStatements(dialect: PostgresDialect())

    #expect(
        calls == [
            MetadataRecordedStatement(
                sql: "CREATE TABLE IF NOT EXISTS \"_perun_migrations\" "
                    + "(\"position\" BIGINT NOT NULL PRIMARY KEY, "
                    + "\"id\" TEXT NOT NULL UNIQUE, "
                    + "\"revision\" BIGINT NOT NULL, "
                    + "\"applied_at\" TIMESTAMPTZ NOT NULL)",
                parameters: [],
                intent: .arbitrary
            ),
            MetadataRecordedStatement(
                sql: "SELECT \"position\", \"id\", \"revision\", \"applied_at\" "
                    + "FROM \"_perun_migrations\" ORDER BY \"position\" ASC",
                parameters: [],
                intent: .arbitrary
            ),
        ]
    )
}

@Test
func metadataStoreRendersExactSQLiteTrackingStatements() async throws {
    let calls = try await recordMetadataStoreStatements(dialect: SQLiteDialect())

    #expect(
        calls == [
            MetadataRecordedStatement(
                sql: "CREATE TABLE IF NOT EXISTS \"_perun_migrations\" "
                    + "(\"position\" BIGINT NOT NULL PRIMARY KEY, "
                    + "\"id\" TEXT NOT NULL UNIQUE, "
                    + "\"revision\" BIGINT NOT NULL, "
                    + "\"applied_at\" TEXT NOT NULL)",
                parameters: [],
                intent: .arbitrary
            ),
            MetadataRecordedStatement(
                sql: "SELECT \"position\", \"id\", \"revision\", \"applied_at\" "
                    + "FROM \"_perun_migrations\" ORDER BY \"position\" ASC",
                parameters: [],
                intent: .arbitrary
            ),
        ]
    )
}

@Test
func metadataStoreDecodesMultipleRowsWithLosslessTimestamps() throws {
    let minimum = SQLTimestamp(microsecondsSinceUnixEpoch: -62_135_596_800_000_000)
    let maximum = SQLTimestamp(microsecondsSinceUnixEpoch: 253_402_300_799_999_999)
    let store = metadataStore()

    let snapshot = try store.decodeSnapshot([
        metadataRow(position: 1, id: "create_users", revision: 1, appliedAt: minimum),
        metadataRow(position: 2, id: "add-email.v2", revision: 7, appliedAt: maximum),
    ])

    #expect(
        snapshot == MigrationMetadataSnapshot(
            rows: [
                MigrationMetadataRow(
                    reference: MigrationReference(
                        position: 1,
                        id: "create_users",
                        revision: 1
                    ),
                    appliedAt: minimum
                ),
                MigrationMetadataRow(
                    reference: MigrationReference(
                        position: 2,
                        id: "add-email.v2",
                        revision: 7
                    ),
                    appliedAt: maximum
                ),
            ]
        )
    )
    #expect(snapshot.rows[0].appliedAt.microsecondsSinceUnixEpoch == -62_135_596_800_000_000)
    #expect(snapshot.rows[1].appliedAt.microsecondsSinceUnixEpoch == 253_402_300_799_999_999)
}

@Test
func metadataSnapshotEqualityIncludesAppliedAtWhileReferencesDoNot() throws {
    let store = metadataStore()
    let earlier = try store.decodeSnapshot([
        metadataRow(
            position: 1,
            id: "create_users",
            revision: 3,
            appliedAt: SQLTimestamp(microsecondsSinceUnixEpoch: 1_234_567)
        ),
    ])
    let later = try store.decodeSnapshot([
        metadataRow(
            position: 1,
            id: "create_users",
            revision: 3,
            appliedAt: SQLTimestamp(microsecondsSinceUnixEpoch: 1_234_568)
        ),
    ])

    #expect(earlier.references == later.references)
    #expect(earlier != later)
}

@Test
func metadataStoreReportsMissingNullAndWrongTypeAsUnreadableForEveryColumn() {
    let store = metadataStore()
    let columns = ["position", "id", "revision", "applied_at"]

    for column in columns {
        var missing = validMetadataValues()
        missing.removeValue(forKey: column)
        #expect(
            throws: MigrationHistoryError.malformedRow(
                rowOrdinal: 1,
                column: column,
                reason: .unreadable
            )
        ) {
            try store.decodeSnapshot([MetadataTestRow(values: missing)])
        }

        var null = validMetadataValues()
        null[column] = .null
        #expect(
            throws: MigrationHistoryError.malformedRow(
                rowOrdinal: 1,
                column: column,
                reason: .unreadable
            )
        ) {
            try store.decodeSnapshot([MetadataTestRow(values: null)])
        }

        var wrongType = validMetadataValues()
        wrongType[column] = .bool(true)
        #expect(
            throws: MigrationHistoryError.malformedRow(
                rowOrdinal: 1,
                column: column,
                reason: .unreadable
            )
        ) {
            try store.decodeSnapshot([MetadataTestRow(values: wrongType)])
        }
    }
}

@Test
func metadataStoreRejectsNonPositivePositionsAndRevisionsAsInvalidValues() {
    let store = metadataStore()

    for column in ["position", "revision"] {
        for value: Int64 in [0, -1, .min] {
            var values = validMetadataValues()
            values[column] = .int(value)

            #expect(
                throws: MigrationHistoryError.malformedRow(
                    rowOrdinal: 1,
                    column: column,
                    reason: .invalidValue
                )
            ) {
                try store.decodeSnapshot([MetadataTestRow(values: values)])
            }
        }
    }
}

@Test
func metadataStoreRejectsInvalidMigrationIDsAsInvalidValues() {
    let store = metadataStore()
    let invalidIDs = [
        "",
        "_starts_with_underscore",
        "contains space",
        "миграция",
        String(repeating: "a", count: 129),
    ]

    for id in invalidIDs {
        var values = validMetadataValues()
        values["id"] = .text(id)

        #expect(
            throws: MigrationHistoryError.malformedRow(
                rowOrdinal: 1,
                column: "id",
                reason: .invalidValue
            )
        ) {
            try store.decodeSnapshot([MetadataTestRow(values: values)])
        }
    }
}

@Test
func metadataStoreUsesOneBasedOrdinalForTheSecondMalformedRow() {
    let store = metadataStore()
    var secondValues = validMetadataValues(position: 2, id: "second")
    secondValues.removeValue(forKey: "revision")

    #expect(
        throws: MigrationHistoryError.malformedRow(
            rowOrdinal: 2,
            column: "revision",
            reason: .unreadable
        )
    ) {
        try store.decodeSnapshot([
            MetadataTestRow(values: validMetadataValues()),
            MetadataTestRow(values: secondValues),
        ])
    }
}

@Test
func metadataStoreReportsMalformedRowsInRowThenColumnOrder() {
    let store = metadataStore()
    var firstRowLastColumnUnreadable = validMetadataValues()
    firstRowLastColumnUnreadable["applied_at"] = .null

    #expect(
        throws: MigrationHistoryError.malformedRow(
            rowOrdinal: 1,
            column: "applied_at",
            reason: .unreadable
        )
    ) {
        try store.decodeSnapshot([
            MetadataTestRow(values: firstRowLastColumnUnreadable),
            MetadataTestRow(values: [:]),
        ])
    }

    #expect(
        throws: MigrationHistoryError.malformedRow(
            rowOrdinal: 1,
            column: "position",
            reason: .invalidValue
        )
    ) {
        try store.decodeSnapshot([
            MetadataTestRow(
                values: [
                    "position": .int(0),
                    "id": .bool(true),
                    "revision": .null,
                    "applied_at": .null,
                ]
            ),
        ])
    }
}

private func metadataStore() -> MigrationMetadataStore {
    MigrationMetadataStore(
        tableName: "_perun_migrations",
        dialect: SQLiteDialect()
    )
}

private func metadataRow(
    position: Int64,
    id: String,
    revision: Int64,
    appliedAt: SQLTimestamp
) -> MetadataTestRow {
    MetadataTestRow(
        values: validMetadataValues(
            position: position,
            id: id,
            revision: revision,
            appliedAt: appliedAt
        )
    )
}

private func validMetadataValues(
    position: Int64 = 1,
    id: String = "create_users",
    revision: Int64 = 1,
    appliedAt: SQLTimestamp = SQLTimestamp(microsecondsSinceUnixEpoch: 1_234_567)
) -> [String: SQLValue] {
    [
        "position": .int(position),
        "id": .text(id),
        "revision": .int(revision),
        "applied_at": .date(appliedAt),
    ]
}

private func recordMetadataStoreStatements(
    dialect: any SQLDialect
) async throws -> [MetadataRecordedStatement] {
    let state = MetadataRecordingState(results: [ExecResult(), ExecResult()])
    let transaction = MetadataRecordingTransaction(state: state)
    let store = MigrationMetadataStore(
        tableName: "_perun_migrations",
        dialect: dialect
    )

    try await store.createIfNeeded(using: transaction)
    _ = try await store.readSnapshot(using: transaction)

    return await state.recordedStatements()
}

private struct MetadataRecordedStatement: Sendable, Equatable {
    let sql: String
    let parameters: [SQLValue]
    let intent: ExecutionIntent
}

private actor MetadataRecordingState {
    private var results: [ExecResult]
    private var statements: [MetadataRecordedStatement] = []

    init(results: [ExecResult]) {
        self.results = results
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) throws -> ExecResult {
        statements.append(
            MetadataRecordedStatement(
                sql: sql,
                parameters: parameters,
                intent: intent
            )
        )
        guard !results.isEmpty else {
            throw MetadataTestError.unexpectedExecution
        }
        return results.removeFirst()
    }

    func recordedStatements() -> [MetadataRecordedStatement] {
        statements
    }
}

private struct MetadataRecordingTransaction: Transaction {
    let state: MetadataRecordingState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(sql, parameters, intent: intent)
    }
}

private struct MetadataTestRow: Row {
    let values: [String: SQLValue]

    func decode<Value: SQLValueConvertible>(
        _ column: String,
        as type: Value.Type
    ) throws -> Value {
        guard let value = values[column] else {
            throw MetadataTestError.missingColumn(column)
        }
        return try Value(sqlValue: value)
    }

    func decodeIfPresent<Value: SQLValueConvertible>(
        _ column: String,
        as type: Value.Type
    ) throws -> Value? {
        guard let value = values[column] else {
            throw MetadataTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try Value(sqlValue: value)
    }
}

private enum MetadataTestError: Error, Sendable, Equatable {
    case missingColumn(String)
    case unexpectedExecution
}
