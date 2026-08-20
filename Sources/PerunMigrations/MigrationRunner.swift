import Foundation
import PerunDBAL

struct MigrationClock: Sendable {
    static let system = MigrationClock {
        SQLTimestamp(Date())
    }

    let now: @Sendable () -> SQLTimestamp
}

extension Migrator {
    /// Applies the pending migration suffix atomically and returns the references committed by
    /// this call.
    ///
    /// The complete pending suffix, its tracking rows, and the final metadata validation share
    /// one exclusive transaction. A body or validation failure therefore rolls back the complete
    /// batch rather than leaving a partially applied release.
    public func migrate() async throws -> MigrationReport {
        try Task.checkCancellation()
        let database = self.database
        let plan = self.plan
        let clock = self.clock
        let dialect = database.dialect
        let store = MigrationMetadataStore(
            tableName: plan.trackingTableName,
            dialect: dialect
        )

        return try await database.withExclusiveTransaction(lockKey: plan.lockKey) { transaction in
            try Task.checkCancellation()
            try await store.createIfNeeded(using: transaction)
            let initialSnapshot = try await store.readSnapshot(using: transaction)
            let status = try plan.status(applied: initialSnapshot.references)
            guard !status.pending.isEmpty else {
                try Task.checkCancellation()
                return MigrationReport(applied: [])
            }

            var expectedRows = initialSnapshot.rows
            var applied: [MigrationReference] = []
            applied.reserveCapacity(status.pending.count)

            let firstPendingIndex = status.applied.count
            for (offset, reference) in status.pending.enumerated() {
                try Task.checkCancellation()
                let migration = plan.migrations[firstPendingIndex + offset]
                let context = MigrationContext(
                    dialect: dialect,
                    transaction: transaction
                )

                do {
                    try await migration.apply(to: context)
                } catch {
                    try? await context.close()
                    throw error
                }
                try await context.close()
                try Task.checkCancellation()

                let row = try await store.insert(
                    reference: reference,
                    appliedAt: clock.now(),
                    using: transaction
                )
                expectedRows.append(row)
                applied.append(reference)
            }

            let finalSnapshot = try await store.readSnapshot(using: transaction)
            guard finalSnapshot.rows == expectedRows else {
                throw MigrationHistoryError.reservedMetadataChanged
            }
            try Task.checkCancellation()
            return MigrationReport(applied: applied)
        }
    }
}
