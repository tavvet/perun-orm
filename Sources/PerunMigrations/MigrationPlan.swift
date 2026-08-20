import PerunDBAL

/// Deterministic failures found while validating a local migration plan.
public enum MigrationPlanError: Error, Sendable, Equatable {
    /// A migration identifier does not match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`.
    case invalidMigrationID(position: Int64, id: String)
    /// A migration revision is not positive.
    case nonPositiveRevision(position: Int64, id: String, revision: Int64)
    /// A migration identifier occurs more than once in the plan.
    case duplicateMigrationID(
        id: String,
        firstPosition: Int64,
        duplicatePosition: Int64
    )
    /// The tracking table name does not match `[a-z_][a-z0-9_]{0,62}` or begins with `sqlite_`.
    case invalidTrackingTableName(String)
}

/// Deterministic failures found while reconciling persisted history with a local plan.
public enum MigrationHistoryError: Error, Sendable, Equatable {
    /// Why a persisted tracking row could not become a valid migration reference.
    public enum MalformedRowReason: Sendable, Equatable {
        /// A required value was missing, null, or could not be decoded as its portable type.
        case unreadable
        /// A decoded value violated migration history constraints.
        case invalidValue
    }

    /// A persisted tracking row could not be decoded or validated.
    case malformedRow(
        rowOrdinal: Int64,
        column: String,
        reason: MalformedRowReason
    )
    /// Persisted positions are not a contiguous one-based sequence.
    case nonContiguousPosition(expected: Int64, actual: MigrationReference)
    /// Persisted history contains a migration after the local plan has ended.
    case unexpectedAppliedMigration(MigrationReference)
    /// The persisted migration at a position differs from the local plan.
    case appliedMigrationMismatch(
        expected: MigrationReference,
        actual: MigrationReference
    )
    /// Reserved tracking metadata changed while migration work was running.
    case reservedMetadataChanged
}

/// The persisted identity of one migration at its canonical plan position.
public struct MigrationReference: Sendable, Hashable {
    /// The positive, one-based position in the complete migration plan.
    public let position: Int64
    /// The stable migration identifier.
    public let id: String
    /// The positive migration revision.
    public let revision: Int64

    init(position: Int64, id: String, revision: Int64) {
        self.position = position
        self.id = id
        self.revision = revision
    }
}

/// A validated snapshot of applied and pending migrations.
public struct MigrationStatus: Sendable, Equatable {
    /// The persisted prefix, in canonical plan order.
    public let applied: [MigrationReference]
    /// The local suffix that has not been applied, retaining full-plan positions.
    public let pending: [MigrationReference]

    init(applied: [MigrationReference], pending: [MigrationReference]) {
        self.applied = applied
        self.pending = pending
    }
}

/// The migrations committed by one successful migration run.
public struct MigrationReport: Sendable, Equatable {
    /// Migrations applied by this call, retaining their full-plan positions.
    public let applied: [MigrationReference]

    init(applied: [MigrationReference]) {
        self.applied = applied
    }
}

/// A validated, ordered migration runner for one logical database.
public struct Migrator: Sendable {
    let database: any ExclusiveTransactionDatabase
    let plan: MigrationPlan
    let clock: MigrationClock

    /// Creates a migrator after synchronously validating its complete local plan.
    ///
    /// Validation finishes before any database operation. Migration array order is canonical;
    /// identifiers are never sorted, normalized, or compared case-insensitively.
    ///
    /// - Parameters:
    ///   - database: The database and exclusive transaction capability used by the runner.
    ///   - migrations: The complete forward-only migration plan in execution order.
    ///   - trackingTableName: The metadata table identifier. It must use lowercase ASCII
    ///     `[a-z_][a-z0-9_]{0,62}` (1 through 63 bytes) and must not begin with `sqlite_`.
    /// - Throws: ``MigrationPlanError`` when any local plan invariant is invalid.
    public init(
        database: any ExclusiveTransactionDatabase,
        migrations: [Migration],
        trackingTableName: String = "_perun_migrations"
    ) throws {
        try self.init(
            database: database,
            migrations: migrations,
            trackingTableName: trackingTableName,
            clock: .system
        )
    }

    init(
        database: any ExclusiveTransactionDatabase,
        migrations: [Migration],
        trackingTableName: String = "_perun_migrations",
        clock: MigrationClock
    ) throws {
        self.database = database
        plan = try MigrationPlan(
            migrations: migrations,
            trackingTableName: trackingTableName
        )
        self.clock = clock
    }
}

struct MigrationPlan: Sendable {
    static let lockNamespace = "perun-migrations/v1"

    let migrations: [Migration]
    let references: [MigrationReference]
    let trackingTableName: String
    let lockKey: DatabaseLockKey

    init(migrations: [Migration], trackingTableName: String) throws {
        var positionsByID: [String: Int64] = [:]
        var references: [MigrationReference] = []
        references.reserveCapacity(migrations.count)

        for (index, migration) in migrations.enumerated() {
            let position = Int64(index) + 1

            guard MigrationValidation.isValidMigrationID(migration.id) else {
                throw MigrationPlanError.invalidMigrationID(
                    position: position,
                    id: migration.id
                )
            }
            guard migration.revision > 0 else {
                throw MigrationPlanError.nonPositiveRevision(
                    position: position,
                    id: migration.id,
                    revision: migration.revision
                )
            }
            if let firstPosition = positionsByID[migration.id] {
                throw MigrationPlanError.duplicateMigrationID(
                    id: migration.id,
                    firstPosition: firstPosition,
                    duplicatePosition: position
                )
            }

            positionsByID[migration.id] = position
            references.append(
                MigrationReference(
                    position: position,
                    id: migration.id,
                    revision: migration.revision
                )
            )
        }

        guard MigrationValidation.isValidTrackingTableName(trackingTableName) else {
            throw MigrationPlanError.invalidTrackingTableName(trackingTableName)
        }

        self.migrations = migrations
        self.references = references
        self.trackingTableName = trackingTableName
        lockKey = DatabaseLockKey(rawValue: Self.fnv1a64(Self.lockNamespace))
    }

    func status(applied: [MigrationReference]) throws -> MigrationStatus {
        for (index, actual) in applied.enumerated() {
            let position = Int64(index) + 1

            guard actual.position == position else {
                throw MigrationHistoryError.nonContiguousPosition(
                    expected: position,
                    actual: actual
                )
            }
            guard references.indices.contains(index) else {
                throw MigrationHistoryError.unexpectedAppliedMigration(actual)
            }

            let expected = references[index]
            guard actual == expected else {
                throw MigrationHistoryError.appliedMigrationMismatch(
                    expected: expected,
                    actual: actual
                )
            }
        }

        return MigrationStatus(
            applied: applied,
            pending: Array(references.dropFirst(applied.count))
        )
    }

    private static func fnv1a64(_ value: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }
}

enum MigrationValidation {
    static func isValidMigrationID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard (1 ... 128).contains(bytes.count), let first = bytes.first else {
            return false
        }
        guard isASCIIAlphaNumeric(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    static func isValidTrackingTableName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1 ... 63).contains(bytes.count), let first = bytes.first else {
            return false
        }
        guard isASCIILowercase(first) || first == 0x5F else {
            return false
        }
        guard bytes.dropFirst().allSatisfy({
            isASCIILowercase($0) || isASCIIDigit($0) || $0 == 0x5F
        }) else {
            return false
        }
        return !name.hasPrefix("sqlite_")
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        isASCIIUppercase(byte) || isASCIILowercase(byte) || isASCIIDigit(byte)
    }

    private static func isASCIIUppercase(_ byte: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(byte)
    }

    private static func isASCIILowercase(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }
}
