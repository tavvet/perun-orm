@testable import PerunMigrations
import Testing

@Test
func migrationStatusAndReportRetainCanonicalReferences() {
    let applied = [
        MigrationReference(position: 1, id: "create_users", revision: 1),
        MigrationReference(position: 2, id: "backfill_users", revision: 3),
    ]
    let pending = [
        MigrationReference(position: 3, id: "index_users", revision: 1),
    ]

    let status = MigrationStatus(applied: applied, pending: pending)
    let report = MigrationReport(applied: pending)

    #expect(status.applied == applied)
    #expect(status.pending == pending)
    #expect(status == MigrationStatus(applied: applied, pending: pending))
    #expect(report.applied == pending)
    #expect(report == MigrationReport(applied: pending))
    #expect(Set(applied).count == applied.count)

    requireSendable(status)
    requireSendable(report)
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
