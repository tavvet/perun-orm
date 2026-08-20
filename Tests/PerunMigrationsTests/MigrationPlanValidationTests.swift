@testable import PerunMigrations
import Testing

@Test
func migrationDefaultsRevisionAndAcceptsIDGrammarBoundaries() throws {
    let oneByte = migration("A")
    let maximumLength = migration(
        "Z" + String(repeating: "a", count: 127),
        revision: Int64.max
    )
    let acceptedVocabulary = migration("9.release_candidate-1")

    #expect(oneByte.revision == 1)

    let plan = try MigrationPlan(
        migrations: [oneByte, maximumLength, acceptedVocabulary],
        trackingTableName: "_perun_migrations"
    )

    #expect(
        plan.references == [
            MigrationReference(position: 1, id: oneByte.id, revision: 1),
            MigrationReference(
                position: 2,
                id: maximumLength.id,
                revision: Int64.max
            ),
            MigrationReference(
                position: 3,
                id: acceptedVocabulary.id,
                revision: 1
            ),
        ]
    )
}

@Test
func migrationPlanRejectsInvalidIDsAtTheirDeclaredPositions() {
    let invalidIDs = [
        "",
        String(repeating: "a", count: 129),
        "-starts-with-dash",
        ".starts-with-dot",
        "_starts_with_underscore",
        "contains space",
        "contains/slash",
        "contains:colon",
        "contains\nnewline",
        "migración",
        "миграция",
        "🚀",
    ]

    for id in invalidIDs {
        #expect(
            throws: MigrationPlanError.invalidMigrationID(
                position: 2,
                id: id
            )
        ) {
            try MigrationPlan(
                migrations: [migration("valid"), migration(id)],
                trackingTableName: "_perun_migrations"
            )
        }
    }
}

@Test
func migrationPlanRejectsNonPositiveRevisions() {
    for revision: Int64 in [0, -1, .min] {
        #expect(
            throws: MigrationPlanError.nonPositiveRevision(
                position: 2,
                id: "invalid_revision",
                revision: revision
            )
        ) {
            try MigrationPlan(
                migrations: [
                    migration("first"),
                    migration("invalid_revision", revision: revision),
                ],
                trackingTableName: "_perun_migrations"
            )
        }
    }
}

@Test
func migrationPlanReportsExactDuplicatePositionsWithoutCaseFolding() throws {
    #expect(
        throws: MigrationPlanError.duplicateMigrationID(
            id: "Repeat",
            firstPosition: 2,
            duplicatePosition: 4
        )
    ) {
        try MigrationPlan(
            migrations: [
                migration("first"),
                migration("Repeat"),
                migration("middle"),
                migration("Repeat"),
            ],
            trackingTableName: "_perun_migrations"
        )
    }

    let caseSensitivePlan = try MigrationPlan(
        migrations: [migration("A"), migration("a")],
        trackingTableName: "_perun_migrations"
    )
    #expect(caseSensitivePlan.references.map(\.id) == ["A", "a"])
}

@Test
func migrationPlanAcceptsTrackingTableGrammarBoundaries() throws {
    let maximumLength = "_" + String(repeating: "a", count: 62)
    let validNames = [
        "_",
        "a",
        "_perun_migrations",
        "migration_history_02",
        "sqlite",
        maximumLength,
    ]

    for name in validNames {
        let plan = try MigrationPlan(
            migrations: [],
            trackingTableName: name
        )
        #expect(plan.trackingTableName == name)
    }
}

@Test
func migrationPlanRejectsNoncanonicalTrackingTableNames() {
    let invalidNames = [
        "",
        "9migrations",
        "Migrations",
        "migRations",
        "migration-history",
        "migration.history",
        "migration history",
        "migración",
        "миграции",
        String(repeating: "a", count: 64),
        "sqlite_",
        "sqlite_schema_history",
    ]

    for name in invalidNames {
        #expect(throws: MigrationPlanError.invalidTrackingTableName(name)) {
            try MigrationPlan(
                migrations: [],
                trackingTableName: name
            )
        }
    }
}

@Test
func migrationPlanPreservesDeclaredOrder() throws {
    let plan = try MigrationPlan(
        migrations: [
            migration("z-last-lexically", revision: 3),
            migration("a-first-lexically", revision: 7),
            migration("middle", revision: 11),
        ],
        trackingTableName: "_perun_migrations"
    )

    #expect(
        plan.references == [
            MigrationReference(
                position: 1,
                id: "z-last-lexically",
                revision: 3
            ),
            MigrationReference(
                position: 2,
                id: "a-first-lexically",
                revision: 7
            ),
            MigrationReference(position: 3, id: "middle", revision: 11),
        ]
    )
}

@Test
func migrationPlanUsesFixedFNVLockKeyVector() throws {
    let plan = try MigrationPlan(
        migrations: [],
        trackingTableName: "_perun_migrations"
    )

    #expect(MigrationPlan.lockNamespace == "perun-migrations/v1")
    #expect(plan.lockKey.rawValue == 2_311_701_755_587_480_641)
}

@Test
func migrationPlanLockKeyIsIndependentOfPlanAndTrackingTable() throws {
    let emptyPlan = try MigrationPlan(
        migrations: [],
        trackingTableName: "_perun_migrations"
    )
    let populatedPlan = try MigrationPlan(
        migrations: [
            migration("second", revision: 42),
            migration("first", revision: 9),
        ],
        trackingTableName: "custom_history"
    )

    #expect(populatedPlan.lockKey == emptyPlan.lockKey)
}

private func migration(
    _ id: String,
    revision: Int64 = 1
) -> Migration {
    Migration(id: id, revision: revision) { _ in }
}
