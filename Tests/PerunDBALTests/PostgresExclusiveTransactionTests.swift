import Foundation
import PerunDBAL
import PerunDBALPostgres
import PerunPGSQL
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresExclusiveTransactionsSerializeAcrossDatabaseInstances() async throws {
    let lockKey = DatabaseLockKey(rawValue: 0x5045_5255_4E02_0001)
    let holder = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(),
        maxConnections: 1
    )
    let contender = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(lockTimeout: "250ms"),
        maxConnections: 1
    )
    let (holderStates, holderStateContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
    let releaseHolder = PostgresExclusiveGate()
    let events = PostgresExclusiveEvents()

    let holderTask = Task {
        do {
            try await holder.withExclusiveTransaction(lockKey: lockKey) { _ in
                await events.append(.holderEntered)
                holderStateContinuation.yield()
                await releaseHolder.wait()
                await events.append(.holderExited)
            }
            holderStateContinuation.finish()
        } catch {
            holderStateContinuation.finish(throwing: error)
            throw error
        }
    }

    do {
        var holderStateIterator = holderStates.makeAsyncIterator()
        _ = try #require(await holderStateIterator.next())

        do {
            try await contender.withExclusiveTransaction(lockKey: lockKey) { _ in
                await events.append(.contenderEntered)
            }
            Issue.record("contender entered while the holder body still owned the lock")
        } catch let error as PerunPGSQL.PerunError {
            guard case let .server(serverError) = error else {
                throw error
            }
            #expect(serverError.sqlState == .lockNotAvailable)
        }

        #expect(await events.snapshot() == [.holderEntered])
        await releaseHolder.open()
        try await holderTask.value

        try await contender.withExclusiveTransaction(lockKey: lockKey) { _ in
            await events.append(.contenderEntered)
        }
        #expect(
            await events.snapshot() == [
                .holderEntered,
                .holderExited,
                .contenderEntered,
            ]
        )
    } catch {
        await releaseHolder.open()
        _ = try? await holderTask.value
        await holder.shutdown()
        await contender.shutdown()
        throw error
    }

    await holder.shutdown()
    await contender.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresExclusiveTransactionLockReleasesAfterCommitAndRollback() async throws {
    let first = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(),
        maxConnections: 1
    )
    let second = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(lockTimeout: "1s"),
        maxConnections: 1
    )
    let commitKey = DatabaseLockKey(rawValue: Int64.max - 7)
    let rollbackKey = DatabaseLockKey(rawValue: Int64.min)

    do {
        let committed = try await first.withExclusiveTransaction(lockKey: commitKey) {
            transaction in
            try await roundTripLockKey(commitKey, transaction: transaction)
        }
        #expect(committed == commitKey.rawValue)

        let afterCommit = try await second.withExclusiveTransaction(lockKey: commitKey) {
            transaction in
            try await roundTripLockKey(commitKey, transaction: transaction)
        }
        #expect(afterCommit == commitKey.rawValue)

        do {
            let _: Void = try await first.withExclusiveTransaction(lockKey: rollbackKey) {
                transaction in
                _ = try await roundTripLockKey(rollbackKey, transaction: transaction)
                throw PostgresExclusiveTestError.expectedRollback
            }
            Issue.record("exclusive transaction unexpectedly committed")
        } catch let error as PostgresExclusiveTestError {
            #expect(error == .expectedRollback)
        }

        let afterRollback = try await second.withExclusiveTransaction(lockKey: rollbackKey) {
            transaction in
            try await roundTripLockKey(rollbackKey, transaction: transaction)
        }
        #expect(afterRollback == rollbackKey.rawValue)
    } catch {
        await first.shutdown()
        await second.shutdown()
        throw error
    }

    await first.shutdown()
    await second.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresExclusiveTransactionReadsFreshSnapshotAfterWaitingForLock() async throws {
    let lockKey = DatabaseLockKey(rawValue: 0x5045_5255_4E02_0003)
    let tableSuffix = UUID().uuidString.replacingOccurrences(
        of: "-",
        with: ""
    ).lowercased()
    let tableName = "perun_exclusive_snapshot_\(tableSuffix)"
    let quotedTableName = "\"\(tableName)\""
    let holder = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(),
        maxConnections: 1
    )
    let contender = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(
            lockTimeout: "15s",
            defaultTransactionIsolation: "repeatable read"
        ),
        maxConnections: 1
    )
    let observer = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(),
        maxConnections: 1
    )
    let (holderStates, holderStateContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
    let releaseHolder = PostgresExclusiveGate()

    do {
        _ = try await observer.execute(
            "CREATE TABLE \(quotedTableName) (marker BIGINT NOT NULL)",
            []
        )
    } catch {
        await holder.shutdown()
        await contender.shutdown()
        await observer.shutdown()
        throw error
    }

    let holderTask = Task {
        do {
            try await holder.withExclusiveTransaction(lockKey: lockKey) { transaction in
                _ = try await transaction.execute(
                    "INSERT INTO \(quotedTableName) (marker) VALUES ($1::bigint)",
                    [.int(73)]
                )
                holderStateContinuation.yield()
                holderStateContinuation.finish()
                await releaseHolder.wait()
            }
        } catch {
            holderStateContinuation.finish(throwing: error)
            throw error
        }
    }

    var contenderTask: Task<PostgresExclusiveSnapshotObservation, Error>?
    do {
        let configuredIsolation = try await contender.withTransaction { transaction in
            try await postgresTransactionIsolation(transaction)
        }
        #expect(configuredIsolation == "repeatable read")

        let contenderPID = try await postgresBackendPID(contender)
        var holderStateIterator = holderStates.makeAsyncIterator()
        _ = try #require(await holderStateIterator.next())

        let waitingTask = Task {
            try await contender.withExclusiveTransaction(lockKey: lockKey) { transaction in
                let isolation = try await postgresTransactionIsolation(transaction)
                let result = try await transaction.execute(
                    "SELECT marker FROM \(quotedTableName)",
                    []
                )
                let row = try #require(result.rows.first)
                return PostgresExclusiveSnapshotObservation(
                    isolation: isolation,
                    marker: try row.decode("marker", as: Int64.self)
                )
            }
        }
        contenderTask = waitingTask

        try await waitForPostgresAdvisoryLockWait(
            backendPID: contenderPID,
            observer: observer
        )
        await releaseHolder.open()
        try await holderTask.value

        let observation = try await waitingTask.value
        #expect(observation.isolation == "read committed")
        #expect(observation.marker == 73)

        _ = try await observer.execute("DROP TABLE \(quotedTableName)", [])
    } catch {
        await releaseHolder.open()
        holderTask.cancel()
        contenderTask?.cancel()
        _ = try? await holderTask.value
        if let contenderTask {
            _ = try? await contenderTask.value
        }
        _ = try? await observer.execute("DROP TABLE IF EXISTS \(quotedTableName)", [])
        await holder.shutdown()
        await contender.shutdown()
        await observer.shutdown()
        throw error
    }

    await holder.shutdown()
    await contender.shutdown()
    await observer.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PERUN_PGSQL_INTEGRATION"] == "1"))
func postgresExclusiveTransactionRejectsASwallowedServerError() async throws {
    let tableSuffix = UUID().uuidString.replacingOccurrences(
        of: "-",
        with: ""
    ).lowercased()
    let tableName = "perun_exclusive_aborted_\(tableSuffix)"
    let quotedTableName = "\"\(tableName)\""
    let database = PostgresDatabase(
        configuration: postgresExclusiveConfiguration(),
        maxConnections: 1
    )

    do {
        _ = try await database.execute(
            "CREATE TABLE \(quotedTableName) (id BIGINT PRIMARY KEY)",
            []
        )
    } catch {
        await database.shutdown()
        throw error
    }

    do {
        do {
            try await database.withExclusiveTransaction(
                lockKey: DatabaseLockKey(rawValue: 0x5045_5255_4E02_0004)
            ) { transaction in
                _ = try await transaction.execute(
                    "INSERT INTO \(quotedTableName) (id) VALUES ($1::bigint)",
                    [.int(1)]
                )

                do {
                    _ = try await transaction.execute(
                        "INSERT INTO \(quotedTableName) (id) VALUES ($1::bigint)",
                        [.int(1)]
                    )
                    Issue.record("duplicate primary key unexpectedly succeeded")
                } catch let error as PerunPGSQL.PerunError {
                    guard case let .server(serverError) = error else {
                        throw error
                    }
                    #expect(serverError.sqlState == .uniqueViolation)
                }
            }
            Issue.record("exclusive transaction accepted a swallowed server error")
        } catch let error as PerunPGSQL.PerunError {
            guard case let .server(serverError) = error else {
                throw error
            }
            #expect(serverError.sqlState == .other("25P02"))
        }

        let result = try await database.execute(
            "SELECT COUNT(*)::bigint AS row_count FROM \(quotedTableName)",
            []
        )
        let row = try #require(result.rows.first)
        #expect(try row.decode("row_count", as: Int64.self) == 0)

        _ = try await database.execute("DROP TABLE \(quotedTableName)", [])
    } catch {
        _ = try? await database.execute("DROP TABLE IF EXISTS \(quotedTableName)", [])
        await database.shutdown()
        throw error
    }

    await database.shutdown()
}

private func roundTripLockKey(
    _ lockKey: DatabaseLockKey,
    transaction: any Transaction
) async throws -> Int64 {
    let result = try await transaction.execute(
        "SELECT $1::bigint AS lock_key",
        [.int(lockKey.rawValue)]
    )
    let row = try #require(result.rows.first)
    return try row.decode("lock_key", as: Int64.self)
}

private struct PostgresExclusiveSnapshotObservation: Sendable {
    let isolation: String
    let marker: Int64
}

private func postgresTransactionIsolation(_ transaction: any Transaction) async throws -> String {
    let result = try await transaction.execute("SHOW transaction_isolation", [])
    let row = try #require(result.rows.first)
    return try row.decode("transaction_isolation", as: String.self)
}

private func postgresBackendPID(_ database: PostgresDatabase) async throws -> Int32 {
    let result = try await database.execute("SELECT pg_backend_pid() AS pid", [])
    let row = try #require(result.rows.first)
    return try row.decode("pid", as: Int32.self)
}

private func waitForPostgresAdvisoryLockWait(
    backendPID: Int32,
    observer: PostgresDatabase
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))

    while clock.now < deadline {
        let result = try await observer.execute(
            """
            SELECT EXISTS (
                SELECT 1
                FROM pg_locks
                WHERE pid = $1::integer
                  AND locktype = 'advisory'
                  AND NOT granted
            ) AS waiting
            """,
            [.int(Int64(backendPID))]
        )
        let row = try #require(result.rows.first)
        if try row.decode("waiting", as: Bool.self) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    throw PostgresExclusiveTestError.advisoryWaitNotObserved
}

private enum PostgresExclusiveTestError: Error, Equatable {
    case advisoryWaitNotObserved
    case expectedRollback
}

private enum PostgresExclusiveEvent: Sendable, Equatable {
    case holderEntered
    case holderExited
    case contenderEntered
}

private actor PostgresExclusiveEvents {
    private var values: [PostgresExclusiveEvent] = []

    func append(_ event: PostgresExclusiveEvent) {
        values.append(event)
    }

    func snapshot() -> [PostgresExclusiveEvent] {
        values
    }
}

private actor PostgresExclusiveGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private func postgresExclusiveConfiguration(
    lockTimeout: String? = nil,
    defaultTransactionIsolation: String? = nil
) -> ConnectionConfiguration {
    let environment = ProcessInfo.processInfo.environment
    let tlsMode: TLSMode
    switch environment["PGSSLMODE"] {
    case "disable":
        tlsMode = .disable
    case "prefer", "allow-plaintext-fallback":
        tlsMode = .allowPlaintextFallback
    case "require", "encrypt-without-verification":
        tlsMode = .encryptWithoutVerification
    default:
        tlsMode = .verifyFull
    }

    var runtimeParameters: [String: String] = [:]
    if let lockTimeout {
        runtimeParameters["options"] = "-c lock_timeout=\(lockTimeout)"
    }
    if let defaultTransactionIsolation {
        runtimeParameters["default_transaction_isolation"] = defaultTransactionIsolation
    }

    return ConnectionConfiguration(
        host: environment["PGHOST"] ?? "localhost",
        port: UInt16(environment["PGPORT"] ?? "") ?? 5_432,
        user: environment["PGUSER"] ?? "perun",
        database: environment["PGDATABASE"] ?? "perun",
        password: environment["PGPASSWORD"],
        tlsMode: tlsMode,
        runtimeParameters: runtimeParameters
    )
}
