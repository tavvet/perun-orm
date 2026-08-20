import Foundation
import PerunDBAL
import PerunDBALSQLite
import PerunSQLite
import Testing

@Test
func sqliteExclusiveTransactionsSerializeSameKeyAcrossClients() async throws {
    try await withFileBackedSQLitePair { first, second in
        try await expectSerializedExclusiveTransactions(
            first: first,
            second: second,
            keys: Array(repeating: DatabaseLockKey(rawValue: 41), count: 6)
        )
    }
}

@Test
func sqliteExclusiveTransactionsSerializeDifferentKeysAcrossClients() async throws {
    try await withFileBackedSQLitePair { first, second in
        try await expectSerializedExclusiveTransactions(
            first: first,
            second: second,
            keys: (0..<6).map { DatabaseLockKey(rawValue: Int64($0 + 1)) }
        )
    }
}

@Test
func sqliteExclusiveTransactionRollbackReleasesWaitingClient() async throws {
    try await withFileBackedSQLitePair { first, second in
        let gate = TransactionGate()
        let (holderStates, holderStateContinuation) =
            AsyncThrowingStream<Void, Error>.makeStream()

        let rollingBack = Task {
            do {
                try await first.withExclusiveTransaction(
                    lockKey: DatabaseLockKey(rawValue: 7)
                ) { transaction in
                    _ = try await transaction.execute(
                        "INSERT INTO exclusive_probe (value) VALUES (?)",
                        [.text("rolled back")]
                    )
                    holderStateContinuation.yield()
                    holderStateContinuation.finish()
                    await gate.waitForRelease()
                    throw RollbackProbeError.expected
                }
            } catch {
                holderStateContinuation.finish(throwing: error)
                throw error
            }
        }

        var waiting: Task<Void, Error>?
        do {
            var holderStateIterator = holderStates.makeAsyncIterator()
            _ = try #require(await holderStateIterator.next())

            let waitingTask = Task {
                try await second.withExclusiveTransaction(
                    lockKey: DatabaseLockKey(rawValue: 7)
                ) { transaction in
                    _ = try await transaction.execute(
                        "INSERT INTO exclusive_probe (value) VALUES (?)",
                        [.text("committed")]
                    )
                }
            }
            waiting = waitingTask

            // Give the second client time to block in BEGIN IMMEDIATE while the first owns
            // the lock.
            try await Task.sleep(for: .milliseconds(50))
            await gate.release()

            do {
                try await rollingBack.value
                Issue.record("exclusive transaction unexpectedly committed")
            } catch RollbackProbeError.expected {}
            try await waitingTask.value

            let result = try await first.execute(
                "SELECT value FROM exclusive_probe ORDER BY value",
                []
            )
            #expect(result.rows.count == 1)
            let row = try #require(result.rows.first)
            #expect(try row.decode("value", as: String.self) == "committed")
        } catch {
            await gate.release()
            rollingBack.cancel()
            if let waiting {
                waiting.cancel()
            }
            _ = try? await rollingBack.value
            if let waiting {
                _ = try? await waiting.value
            }
            throw error
        }
    }
}

@Test
func sqliteExclusiveTransactionReadsCommittedRowAfterLockRetry() async throws {
    try await withFileBackedSQLitePair(secondBusyTimeout: .milliseconds(50)) { first, second in
        let gate = TransactionGate()
        let contenderEntries = BodyEntryProbe()
        let lockKey = DatabaseLockKey(rawValue: 73)
        let (holderStates, holderStateContinuation) =
            AsyncThrowingStream<Void, Error>.makeStream()

        let holder = Task {
            do {
                try await first.withExclusiveTransaction(lockKey: lockKey) { transaction in
                    _ = try await transaction.execute(
                        "INSERT INTO exclusive_probe (value) VALUES (?)",
                        [.text("committed")]
                    )
                    holderStateContinuation.yield()
                    holderStateContinuation.finish()
                    await gate.waitForRelease()
                }
            } catch {
                holderStateContinuation.finish(throwing: error)
                throw error
            }
        }

        do {
            var holderStateIterator = holderStates.makeAsyncIterator()
            _ = try #require(await holderStateIterator.next())

            do {
                try await second.withExclusiveTransaction(lockKey: lockKey) { _ in
                    await contenderEntries.record()
                }
                Issue.record("contender entered before acquiring SQLite's write reservation")
            } catch let error as PerunSQLite.PerunError {
                let sqliteError = try #require(error.sqliteError)
                #expect(sqliteError.resultCode.isBusy)
            }
            #expect(await contenderEntries.count == 0)

            await gate.release()
            try await holder.value

            let value = try await second.withExclusiveTransaction(lockKey: lockKey) {
                transaction in
                await contenderEntries.record()
                let result = try await transaction.execute(
                    "SELECT value FROM exclusive_probe",
                    []
                )
                let row = try #require(result.rows.first)
                return try row.decode("value", as: String.self)
            }
            #expect(value == "committed")
            #expect(await contenderEntries.count == 1)
        } catch {
            await gate.release()
            holder.cancel()
            _ = try? await holder.value
            throw error
        }
    }
}

@Test
func sqliteCancelledExclusiveWaiterDoesNotEnterBody() async throws {
    try await withFileBackedSQLitePair { first, second in
        let gate = TransactionGate()
        let contenderEntries = BodyEntryProbe()
        let lockKey = DatabaseLockKey(rawValue: 89)
        let (holderStates, holderStateContinuation) =
            AsyncThrowingStream<Void, Error>.makeStream()

        let holder = Task {
            do {
                try await first.withExclusiveTransaction(lockKey: lockKey) { _ in
                    holderStateContinuation.yield()
                    holderStateContinuation.finish()
                    await gate.waitForRelease()
                }
            } catch {
                holderStateContinuation.finish(throwing: error)
                throw error
            }
        }

        var contender: Task<Void, Error>?
        do {
            var holderStateIterator = holderStates.makeAsyncIterator()
            _ = try #require(await holderStateIterator.next())

            let (contenderStates, contenderStateContinuation) =
                AsyncThrowingStream<Void, Error>.makeStream()
            let contenderTask = Task {
                contenderStateContinuation.yield()
                contenderStateContinuation.finish()
                try await second.withExclusiveTransaction(lockKey: lockKey) { transaction in
                    await contenderEntries.record()
                    _ = try await transaction.execute(
                        "INSERT INTO exclusive_probe (value) VALUES (?)",
                        [.text("cancelled contender")]
                    )
                }
            }
            contender = contenderTask

            var contenderStateIterator = contenderStates.makeAsyncIterator()
            _ = try #require(await contenderStateIterator.next())
            // BEGIN IMMEDIATE is uninterruptible while SQLite waits for the holder's reservation.
            try await Task.sleep(for: .milliseconds(50))
            contenderTask.cancel()
            await gate.release()
            try await holder.value

            var receivedCancellation = false
            do {
                try await contenderTask.value
                Issue.record("cancelled contender unexpectedly committed")
            } catch is CancellationError {
                receivedCancellation = true
            } catch {
                Issue.record("cancelled contender threw an unexpected error: \(error)")
            }
            #expect(receivedCancellation)
            #expect(await contenderEntries.count == 0)

            let afterCancellation = try await first.execute(
                "SELECT value FROM exclusive_probe",
                []
            )
            #expect(afterCancellation.rows.isEmpty)

            try await second.withExclusiveTransaction(lockKey: lockKey) { transaction in
                _ = try await transaction.execute(
                    "INSERT INTO exclusive_probe (value) VALUES (?)",
                    [.text("recovered")]
                )
            }
            let afterRecovery = try await first.execute(
                "SELECT value FROM exclusive_probe",
                []
            )
            #expect(afterRecovery.rows.count == 1)
            let row = try #require(afterRecovery.rows.first)
            #expect(try row.decode("value", as: String.self) == "recovered")
        } catch {
            await gate.release()
            holder.cancel()
            contender?.cancel()
            _ = try? await holder.value
            if let contender {
                _ = try? await contender.value
            }
            throw error
        }
    }
}

private func expectSerializedExclusiveTransactions(
    first: SQLiteDatabase,
    second: SQLiteDatabase,
    keys: [DatabaseLockKey]
) async throws {
    let probe = ExclusiveActivityProbe()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, key) in keys.enumerated() {
            let database = index.isMultiple(of: 2) ? first : second
            group.addTask {
                try await database.withExclusiveTransaction(lockKey: key) { _ in
                    try await probe.measure {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
        }
        try await group.waitForAll()
    }

    let snapshot = await probe.snapshot()
    #expect(snapshot.maximumActive == 1)
    #expect(snapshot.completed == keys.count)
}

private func withFileBackedSQLitePair<T: Sendable>(
    secondBusyTimeout: Duration = .seconds(10),
    _ body: @Sendable (SQLiteDatabase, SQLiteDatabase) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "perun-exclusive-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )

    var firstConfiguration = SQLiteConfiguration(
        path: directory.appendingPathComponent("database.sqlite").path,
        journalMode: .wal
    )
    firstConfiguration.busyTimeout = .seconds(10)
    var secondConfiguration = firstConfiguration
    secondConfiguration.busyTimeout = secondBusyTimeout

    // Independent single-connection clients prove exclusion comes from the SQLite file lock,
    // not from one pool serializing checkout.
    let first = SQLiteDatabase(
        client: SQLiteClient(configuration: firstConfiguration, maxConnections: 1)
    )
    let second = SQLiteDatabase(
        client: SQLiteClient(configuration: secondConfiguration, maxConnections: 1)
    )

    do {
        _ = try await first.execute(
            "CREATE TABLE exclusive_probe (value TEXT NOT NULL)",
            []
        )
        _ = try await second.execute("SELECT value FROM exclusive_probe", [])
        let result = try await body(first, second)
        await first.shutdown()
        await second.shutdown()
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        await first.shutdown()
        await second.shutdown()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private actor ExclusiveActivityProbe {
    private var active = 0
    private var maximumActive = 0
    private var completed = 0

    func measure(
        _ operation: @Sendable () async throws -> Void
    ) async rethrows {
        active += 1
        maximumActive = max(maximumActive, active)
        defer {
            active -= 1
            completed += 1
        }
        try await operation()
    }

    func snapshot() -> (maximumActive: Int, completed: Int) {
        (maximumActive, completed)
    }
}

private actor BodyEntryProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor TransactionGate {
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum RollbackProbeError: Error {
    case expected
}
