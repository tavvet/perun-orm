@testable import PerunMigrations
import Testing

@Test
func emptyPlanAndHistoryProduceEmptyStatus() throws {
    let status = try migrationHistoryPlan([]).status(applied: [])

    #expect(status.applied.isEmpty)
    #expect(status.pending.isEmpty)
}

@Test
func emptyHistoryPreservesUnsortedCanonicalPlanOrderAndOneBasedPositions() throws {
    let plan = try migrationHistoryPlan([
        ("z-last-lexically", 3),
        ("a-first-lexically", 1),
        ("m-middle-lexically", 2),
    ])

    let status = try plan.status(applied: [])

    #expect(status.applied.isEmpty)
    #expect(status.pending == [
        migrationHistoryReference(1, "z-last-lexically", 3),
        migrationHistoryReference(2, "a-first-lexically", 1),
        migrationHistoryReference(3, "m-middle-lexically", 2),
    ])
}

@Test
func exactPartialHistoryProducesAppliedPrefixAndPositionedPendingSuffix() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("backfill_users", 2),
        ("index_users", 1),
    ])
    let applied = [
        migrationHistoryReference(1, "create_users", 1),
        migrationHistoryReference(2, "backfill_users", 2),
    ]

    let status = try plan.status(applied: applied)

    #expect(status.applied == applied)
    #expect(status.pending == [
        migrationHistoryReference(3, "index_users", 1),
    ])
}

@Test
func exactFullHistoryProducesNoPendingMigrations() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("index_users", 4),
    ])
    let applied = [
        migrationHistoryReference(1, "create_users", 1),
        migrationHistoryReference(2, "index_users", 4),
    ]

    let status = try plan.status(applied: applied)

    #expect(status.applied == applied)
    #expect(status.pending.isEmpty)
}

@Test
func missingPersistedRowIsReportedAsNonContiguousPosition() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("backfill_users", 1),
        ("index_users", 1),
    ])
    let first = migrationHistoryReference(1, "create_users", 1)
    let actual = migrationHistoryReference(3, "index_users", 1)

    #expect(
        throws: MigrationHistoryError.nonContiguousPosition(
            expected: 2,
            actual: actual
        )
    ) {
        try plan.status(applied: [first, actual])
    }
}

@Test
func appliedMigrationAfterPlanEndIsUnexpected() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
    ])
    let first = migrationHistoryReference(1, "create_users", 1)
    let actual = migrationHistoryReference(2, "legacy_extra", 1)

    #expect(
        throws: MigrationHistoryError.unexpectedAppliedMigration(actual)
    ) {
        try plan.status(applied: [first, actual])
    }
}

@Test
func removingAppliedMigrationFromLocalPlanIsHistoryMismatch() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("index_users", 1),
    ])
    let expected = migrationHistoryReference(2, "index_users", 1)
    let actual = migrationHistoryReference(2, "backfill_users", 1)

    #expect(
        throws: MigrationHistoryError.appliedMigrationMismatch(
            expected: expected,
            actual: actual
        )
    ) {
        try plan.status(applied: [
            migrationHistoryReference(1, "create_users", 1),
            actual,
            migrationHistoryReference(3, "index_users", 1),
        ])
    }
}

@Test
func reorderingAppliedMigrationsIsHistoryMismatch() throws {
    let plan = try migrationHistoryPlan([
        ("backfill_users", 1),
        ("create_users", 1),
    ])
    let expected = migrationHistoryReference(1, "backfill_users", 1)
    let actual = migrationHistoryReference(1, "create_users", 1)

    #expect(
        throws: MigrationHistoryError.appliedMigrationMismatch(
            expected: expected,
            actual: actual
        )
    ) {
        try plan.status(applied: [
            actual,
            migrationHistoryReference(2, "backfill_users", 1),
        ])
    }
}

@Test
func insertingMigrationIntoAppliedPrefixIsHistoryMismatch() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("new_middle_step", 1),
        ("backfill_users", 1),
    ])
    let expected = migrationHistoryReference(2, "new_middle_step", 1)
    let actual = migrationHistoryReference(2, "backfill_users", 1)

    #expect(
        throws: MigrationHistoryError.appliedMigrationMismatch(
            expected: expected,
            actual: actual
        )
    ) {
        try plan.status(applied: [
            migrationHistoryReference(1, "create_users", 1),
            actual,
        ])
    }
}

@Test
func changingAppliedMigrationRevisionIsHistoryMismatch() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 2),
    ])
    let expected = migrationHistoryReference(1, "create_users", 2)
    let actual = migrationHistoryReference(1, "create_users", 1)

    #expect(
        throws: MigrationHistoryError.appliedMigrationMismatch(
            expected: expected,
            actual: actual
        )
    ) {
        try plan.status(applied: [actual])
    }
}

@Test
func historyReconciliationReportsEarliestRowErrorBeforeLaterErrors() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
        ("backfill_users", 1),
    ])
    let expected = migrationHistoryReference(1, "create_users", 1)
    let firstActual = migrationHistoryReference(1, "wrong_first", 1)
    let laterActual = migrationHistoryReference(7, "wrong_later", 9)

    #expect(
        throws: MigrationHistoryError.appliedMigrationMismatch(
            expected: expected,
            actual: firstActual
        )
    ) {
        try plan.status(applied: [firstActual, laterActual])
    }
}

@Test
func positionValidationPrecedesBoundsAndValueChecksForTheSameRow() throws {
    let plan = try migrationHistoryPlan([
        ("create_users", 1),
    ])
    let first = migrationHistoryReference(1, "create_users", 1)
    let actual = migrationHistoryReference(9, "unexpected", 7)

    #expect(
        throws: MigrationHistoryError.nonContiguousPosition(
            expected: 2,
            actual: actual
        )
    ) {
        try plan.status(applied: [first, actual])
    }
}

private func migrationHistoryPlan(
    _ specifications: [(id: String, revision: Int64)]
) throws -> MigrationPlan {
    try MigrationPlan(
        migrations: specifications.map { specification in
            Migration(
                id: specification.id,
                revision: specification.revision
            ) { _ in }
        },
        trackingTableName: "_perun_migrations"
    )
}

private func migrationHistoryReference(
    _ position: Int64,
    _ id: String,
    _ revision: Int64
) -> MigrationReference {
    MigrationReference(
        position: position,
        id: id,
        revision: revision
    )
}
