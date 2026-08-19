import PerunDBAL
import PerunDBALSQLite
@testable import PerunORM
import Testing

@Test
func sessionFetchExecutesTheQueryAndRefreshesReturnedIdentitySnapshots() async throws {
    let before = FetchRecord(id: 1, name: "before", nickname: nil, isActive: true)
    let refreshed = FetchRecord(id: 1, name: "refreshed", nickname: "one", isActive: true)
    let second = FetchRecord(id: 2, name: "second", nickname: nil, isActive: true)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(before)])),
        .result(ExecResult(rows: [fetchRow(refreshed), fetchRow(second)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 1) == before)

    let predicate = try Predicate<FetchRecord>.eq(\FetchRecord.isActive, true)
    let query = try Query(FetchRecord.self)
        .where(predicate)
        .order(by: \FetchRecord.name, desc: true)
        .limit(2, offset: 1)
    let fetched = try await session.fetch(query)

    #expect(fetched == [refreshed, second])
    #expect(try await session.find(FetchRecord.self, 1) == refreshed)
    #expect(try await session.find(FetchRecord.self, 2) == second)
    #expect(await state.calls == [
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(1), .int(2)]
        ),
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"is_active\" = ? ORDER BY \"name\" DESC LIMIT ? OFFSET ?",
            parameters: [.bool(true), .int(2), .int(1)]
        ),
    ])
}

@Test
func sessionFetchRejectsInvalidBatchesWithoutPartiallyRefreshingIdentity() async throws {
    let before = FetchRecord(id: 3, name: "before", nickname: nil, isActive: true)
    let changed = FetchRecord(id: 3, name: "changed", nickname: nil, isActive: false)
    let malformed = FetchRow(values: [
        "id": .int(4),
        "nickname": .null,
        "is_active": .bool(true),
    ])
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(before)])),
        .result(ExecResult(rows: [fetchRow(changed), malformed])),
        .result(ExecResult(rows: [fetchRow(changed), fetchRow(changed)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 3) == before)
    let query = try Query(FetchRecord.self)

    do {
        _ = try await session.fetch(query)
        Issue.record("fetch accepted a partially malformed result")
    } catch let error as FetchTestError {
        #expect(error == .missingColumn("name"))
    }
    #expect(try await session.find(FetchRecord.self, 3) == before)

    do {
        _ = try await session.fetch(query)
        Issue.record("fetch accepted duplicate primary keys")
    } catch let error as ORMError {
        #expect(
            error == .multipleRowsForPrimaryKey(
                table: "fetch\"records",
                primaryKey: .int(3)
            )
        )
    }
    #expect(try await session.find(FetchRecord.self, 3) == before)
    #expect(await state.calls.count == 3)
}

@Test
func unitOfWorkFetchStagesAndPromotesTheWholeBatch() async throws {
    let before = FetchRecord(id: 5, name: "before", nickname: nil, isActive: true)
    let refreshed = FetchRecord(id: 5, name: "refreshed", nickname: "five", isActive: false)
    let second = FetchRecord(id: 6, name: "second", nickname: nil, isActive: true)
    let state = FetchDatabaseState(
        directResponses: [.result(ExecResult(rows: [fetchRow(before)]))],
        transactionResponses: [
            .result(ExecResult(rows: [fetchRow(refreshed), fetchRow(second)])),
        ]
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 5) == before)
    let query = try Query(FetchRecord.self).order(by: \FetchRecord.id)

    let fetched = try await session.withUnitOfWork { unitOfWork in
        let fetched = try await unitOfWork.fetch(query)
        #expect(try await unitOfWork.find(FetchRecord.self, 5) == refreshed)
        #expect(try await unitOfWork.find(FetchRecord.self, 6) == second)
        return fetched
    }

    #expect(fetched == [refreshed, second])
    #expect(try await session.find(FetchRecord.self, 5) == refreshed)
    #expect(try await session.find(FetchRecord.self, 6) == second)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction])
}

@Test
func unitOfWorkFetchHydratesAtomicallyAndRemainsRecoverable() async throws {
    let before = FetchRecord(id: 7, name: "before", nickname: nil, isActive: true)
    let changed = FetchRecord(id: 7, name: "changed", nickname: nil, isActive: false)
    let malformed = FetchRow(values: [
        "id": .int(8),
        "nickname": .null,
        "is_active": .bool(true),
    ])
    let state = FetchDatabaseState(
        directResponses: [.result(ExecResult(rows: [fetchRow(before)]))],
        transactionResponses: [
            .result(ExecResult(rows: [fetchRow(changed), malformed])),
        ]
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 7) == before)
    let query = try Query(FetchRecord.self)

    try await session.withUnitOfWork { unitOfWork in
        do {
            _ = try await unitOfWork.fetch(query)
            Issue.record("unit-of-work fetch accepted a malformed batch")
        } catch let error as FetchTestError {
            #expect(error == .missingColumn("name"))
        }
        #expect(try await unitOfWork.find(FetchRecord.self, 7) == before)
    }

    #expect(try await session.find(FetchRecord.self, 7) == before)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction])
}

@Test
func bodyFailureDoesNotPromoteUnitOfWorkFetchResults() async throws {
    let before = FetchRecord(id: 9, name: "before", nickname: nil, isActive: true)
    let changed = FetchRecord(id: 9, name: "changed", nickname: "nine", isActive: false)
    let state = FetchDatabaseState(
        directResponses: [.result(ExecResult(rows: [fetchRow(before)]))],
        transactionResponses: [.result(ExecResult(rows: [fetchRow(changed)]))]
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 9) == before)
    let query = try Query(FetchRecord.self)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            let fetched = try await unitOfWork.fetch(query)
            #expect(fetched == [changed])
            throw FetchTestError.rollback
        }
        Issue.record("failing fetch unit of work unexpectedly committed")
    } catch let error as FetchTestError {
        #expect(error == .rollback)
    }

    #expect(try await session.find(FetchRecord.self, 9) == before)
    #expect(await state.commits == 0)
}

@Test
func commitFailureDoesNotPromoteUnitOfWorkFetchResults() async throws {
    let before = FetchRecord(id: 11, name: "before", nickname: nil, isActive: true)
    let changed = FetchRecord(id: 11, name: "changed", nickname: nil, isActive: false)
    let state = FetchDatabaseState(
        directResponses: [.result(ExecResult(rows: [fetchRow(before)]))],
        transactionResponses: [.result(ExecResult(rows: [fetchRow(changed)]))],
        failCommit: true
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, 11) == before)
    let query = try Query(FetchRecord.self)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            let fetched = try await unitOfWork.fetch(query)
            #expect(fetched == [changed])
        }
        Issue.record("fetch unit of work ignored a commit failure")
    } catch let error as FetchTestError {
        #expect(error == .commitFailed)
    }

    #expect(try await session.find(FetchRecord.self, 11) == before)
    #expect(await state.commits == 1)
}

@Test
func swallowedFetchExecutorFailureForcesTheUnitOfWorkToRollBack() async throws {
    let state = FetchDatabaseState(
        transactionResponses: [.failure(.executorFailed)]
    )
    let session = Session(database: FetchDatabase(state: state))
    let query = try Query(FetchRecord.self)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.fetch(query)
                Issue.record("fetch ignored an executor failure")
            } catch let error as FetchTestError {
                #expect(error == .executorFailed)
            }
        }
        Issue.record("unit of work committed after a swallowed fetch failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
    #expect(await state.calls.map(\.scope) == [.transaction])
}

@Test
func sessionFirstTightensTheLimitAndRefreshesItsIdentitySnapshot() async throws {
    let first = FetchRecord(id: 13, name: "first", nickname: nil, isActive: true)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(first)])),
        .result(ExecResult(rows: [])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    let active = try Predicate<FetchRecord>.eq(\FetchRecord.isActive, true)
    let query = try Query(FetchRecord.self)
        .where(active)
        .order(by: \FetchRecord.id, desc: true)
        .limit(5, offset: 2)

    #expect(try await session.first(query) == first)
    #expect(try await session.find(FetchRecord.self, first.id) == first)
    #expect(try await session.first(Query(FetchRecord.self).limit(0)) == nil)
    #expect(await state.calls == [
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"is_active\" = ? ORDER BY \"id\" DESC LIMIT ? OFFSET ?",
            parameters: [.bool(true), .int(1), .int(2)]
        ),
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" LIMIT ?",
            parameters: [.int(0)]
        ),
    ])
}

@Test
func unitOfWorkFirstStagesAndPromotesItsSnapshot() async throws {
    let first = FetchRecord(id: 14, name: "transactional", nickname: "first", isActive: true)
    let state = FetchDatabaseState(
        transactionResponses: [.result(ExecResult(rows: [fetchRow(first)]))]
    )
    let session = Session(database: FetchDatabase(state: state))
    let query = try Query(FetchRecord.self).order(by: \FetchRecord.id)

    let returned = try await session.withUnitOfWork { unitOfWork in
        let returned = try await unitOfWork.first(query)
        #expect(try await unitOfWork.find(FetchRecord.self, first.id) == first)
        return returned
    }

    #expect(returned == first)
    #expect(try await session.find(FetchRecord.self, first.id) == first)
    #expect(await state.commits == 1)
    #expect(await state.calls == [
        FetchDatabaseCall(
            scope: .transaction,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" ORDER BY \"id\" ASC LIMIT ?",
            parameters: [.int(1)]
        ),
    ])
}

@Test
func sessionCountIgnoresOrderingAndPaginationWithoutChangingIdentity() async throws {
    let cached = FetchRecord(id: 15, name: "cached", nickname: nil, isActive: true)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(cached)])),
        .result(ExecResult(rows: [countRow(2)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, cached.id) == cached)

    let active = try Predicate<FetchRecord>.eq(\FetchRecord.isActive, true)
    let query = try Query(FetchRecord.self)
        .where(active)
        .order(by: \FetchRecord.name, desc: true)
        .limit(1, offset: 7)

    #expect(try await session.count(query) == 2)
    #expect(try await session.find(FetchRecord.self, cached.id) == cached)
    #expect(await state.calls == [
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
            parameters: [.int(cached.id), .int(2)]
        ),
        FetchDatabaseCall(
            scope: .direct,
            sql: "SELECT COUNT(*) AS \"count\" FROM \"fetch\"\"records\" WHERE \"is_active\" = ?",
            parameters: [.bool(true)]
        ),
    ])
}

@Test
func unitOfWorkCountResultErrorsAreRecoverable() async throws {
    let malformed = FetchRow(values: ["wrong": .int(3)])
    let state = FetchDatabaseState(transactionResponses: [
        .result(ExecResult(rows: [])),
        .result(ExecResult(rows: [countRow(1), countRow(1)])),
        .result(ExecResult(rows: [malformed])),
        .result(ExecResult(rows: [countRow(4)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    let query = try Query(FetchRecord.self)

    try await session.withUnitOfWork { unitOfWork in
        for actual in [0, 2] {
            do {
                _ = try await unitOfWork.count(query)
                Issue.record("count accepted \(actual) result rows")
            } catch let error as ORMError {
                #expect(
                    error == .unexpectedCountResultRowCount(
                        table: "fetch\"records",
                        actual: actual
                    )
                )
            }
        }

        do {
            _ = try await unitOfWork.count(query)
            Issue.record("count accepted a row without its result column")
        } catch let error as FetchTestError {
            #expect(error == .missingColumn(SQLCount.resultColumn))
        }

        #expect(try await unitOfWork.count(query) == 4)
    }

    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [
        .transaction,
        .transaction,
        .transaction,
        .transaction,
    ])
}

@Test
func swallowedCountExecutorFailureForcesTheUnitOfWorkToRollBack() async throws {
    let state = FetchDatabaseState(
        transactionResponses: [.failure(.executorFailed)]
    )
    let session = Session(database: FetchDatabase(state: state))
    let query = try Query(FetchRecord.self)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.count(query)
                Issue.record("count ignored an executor failure")
            } catch let error as FetchTestError {
                #expect(error == .executorFailed)
            }
        }
        Issue.record("unit of work committed after a swallowed count failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.commits == 0)
    #expect(await state.calls.map(\.scope) == [.transaction])
}

@Test
func sessionRawFetchKeepsDeleteReturningRowsDetachedAndInvalidatesEveryKey() async throws {
    let beforeFirst = FetchRecord(id: 21, name: "before-first", nickname: nil, isActive: true)
    let beforeSecond = FetchRecord(id: 22, name: "before-second", nickname: nil, isActive: true)
    let deletedFirst = FetchRecord(id: 21, name: "deleted-first", nickname: "raw", isActive: false)
    let freshSecond = FetchRecord(id: 22, name: "fresh-second", nickname: nil, isActive: false)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(beforeFirst)])),
        .result(ExecResult(rows: [fetchRow(beforeSecond)])),
        .result(ExecResult(rows: [fetchRow(deletedFirst)])),
        .result(ExecResult(rows: [])),
        .result(ExecResult(rows: [fetchRow(freshSecond)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, beforeFirst.id) == beforeFirst)
    #expect(try await session.find(FetchRecord.self, beforeSecond.id) == beforeSecond)

    let fetched = try await session.fetch(
        FetchRecord.self,
        sql: "DELETE FROM \"fetch\"\"records\" WHERE \"id\" = ? RETURNING *",
        params: [.int(beforeFirst.id)]
    )

    #expect(fetched == [deletedFirst])
    #expect(try await session.find(FetchRecord.self, beforeFirst.id) == nil)
    #expect(try await session.find(FetchRecord.self, beforeSecond.id) == freshSecond)
    #expect(await state.calls.map(\.sql) == [
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "DELETE FROM \"fetch\"\"records\" WHERE \"id\" = ? RETURNING *",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
    ])
    #expect(await state.calls[2].parameters == [.int(beforeFirst.id)])
}

@Test
func sessionRawFetchFailureCannotLeaveOldOrPartiallyHydratedSnapshots() async throws {
    let before = FetchRecord(id: 23, name: "before", nickname: nil, isActive: true)
    let partial = FetchRecord(id: 23, name: "partial", nickname: nil, isActive: false)
    let fresh = FetchRecord(id: 23, name: "fresh", nickname: "after", isActive: false)
    let malformed = FetchRow(values: [
        "id": .int(24),
        "nickname": .null,
        "is_active": .bool(true),
    ])
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(before)])),
        .result(ExecResult(rows: [fetchRow(partial), malformed])),
        .result(ExecResult(rows: [fetchRow(fresh)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, before.id) == before)

    do {
        _ = try await session.fetch(FetchRecord.self, sql: "raw-malformed")
        Issue.record("raw fetch accepted a partially malformed batch")
    } catch let error as FetchTestError {
        #expect(error == .missingColumn("name"))
    }

    #expect(try await session.find(FetchRecord.self, before.id) == fresh)
    #expect(await state.calls.map(\.sql) == [
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "raw-malformed",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
    ])
}

@Test
func failedDirectRawExecutionInvalidatesCachedIdentity() async throws {
    let before = FetchRecord(id: 25, name: "before", nickname: nil, isActive: true)
    let fresh = FetchRecord(id: 25, name: "fresh", nickname: nil, isActive: false)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(before)])),
        .failure(.executorFailed),
        .result(ExecResult(rows: [fetchRow(fresh)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, before.id) == before)

    do {
        _ = try await session.execute("raw-unknown-outcome")
        Issue.record("raw execution unexpectedly succeeded")
    } catch let error as FetchTestError {
        #expect(error == .executorFailed)
    }

    #expect(try await session.find(FetchRecord.self, before.id) == fresh)
    #expect(await state.calls.map(\.sql) == [
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "raw-unknown-outcome",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
    ])
}

@Test
func failedDirectRawFetchExecutionInvalidatesCachedIdentity() async throws {
    let before = FetchRecord(id: 31, name: "before", nickname: nil, isActive: true)
    let fresh = FetchRecord(id: 31, name: "fresh", nickname: nil, isActive: false)
    let state = FetchDatabaseState(directResponses: [
        .result(ExecResult(rows: [fetchRow(before)])),
        .failure(.executorFailed),
        .result(ExecResult(rows: [fetchRow(fresh)])),
    ])
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, before.id) == before)

    do {
        _ = try await session.fetch(FetchRecord.self, sql: "raw-fetch-unknown-outcome")
        Issue.record("raw fetch unexpectedly succeeded")
    } catch let error as FetchTestError {
        #expect(error == .executorFailed)
    }

    #expect(try await session.find(FetchRecord.self, before.id) == fresh)
    #expect(await state.calls.map(\.sql) == [
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
        "raw-fetch-unknown-outcome",
        "SELECT \"id\", \"name\", \"nickname\", \"is_active\" FROM \"fetch\"\"records\" WHERE \"id\" = ? LIMIT ?",
    ])
}

@Test
func rawFetchRevisionPreventsAnEarlierFindFromRestoringStaleIdentity() async throws {
    let stale = FetchRecord(id: 26, name: "stale", nickname: nil, isActive: true)
    let raw = FetchRecord(id: 26, name: "raw", nickname: "fresh", isActive: false)
    let state = RawConcurrencyState(stale: stale, raw: raw)
    let session = Session(database: RawConcurrencyDatabase(state: state))
    let earlierFind = Task {
        try await session.find(FetchRecord.self, stale.id)
    }

    await state.waitUntilFindStarted()
    let rawResult: [FetchRecord]
    do {
        rawResult = try await session.fetch(
            FetchRecord.self,
            sql: RawConcurrencyState.rawSQL
        )
    } catch {
        await state.releaseFind()
        _ = try? await earlierFind.value
        throw error
    }
    #expect(rawResult == [raw])
    await state.releaseFind()

    #expect(try await earlierFind.value == stale)
    #expect(try await session.find(FetchRecord.self, stale.id) == raw)
    #expect(await state.calls.count == 3)
    #expect(await state.calls[1].sql == RawConcurrencyState.rawSQL)
}

@Test
func unitOfWorkRawFetchClearsEarlierOverlayAndKeepsDeleteReturningRowsDetached() async throws {
    let beforeFirst = FetchRecord(id: 27, name: "before-first", nickname: nil, isActive: true)
    let beforeSecond = FetchRecord(id: 28, name: "before-second", nickname: nil, isActive: true)
    let stagedFirst = FetchRecord(id: 27, name: "staged-first", nickname: nil, isActive: false)
    let deletedSecond = FetchRecord(id: 28, name: "deleted-second", nickname: "raw", isActive: false)
    let freshFirst = FetchRecord(id: 27, name: "fresh-first", nickname: "db", isActive: false)
    let state = FetchDatabaseState(
        directResponses: [
            .result(ExecResult(rows: [fetchRow(beforeFirst)])),
            .result(ExecResult(rows: [fetchRow(beforeSecond)])),
            .result(ExecResult(rows: [])),
            .result(ExecResult(rows: [fetchRow(freshFirst)])),
        ],
        transactionResponses: [
            .result(ExecResult(rows: [fetchRow(stagedFirst)])),
            .result(ExecResult(rows: [fetchRow(deletedSecond)])),
        ]
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, beforeFirst.id) == beforeFirst)
    #expect(try await session.find(FetchRecord.self, beforeSecond.id) == beforeSecond)
    let query = try Query(FetchRecord.self)

    try await session.withUnitOfWork { unitOfWork in
        let staged = try await unitOfWork.fetch(query)
        #expect(staged == [stagedFirst])
        let rawFetched = try await unitOfWork.fetch(
            FetchRecord.self,
            sql: "DELETE FROM \"fetch\"\"records\" WHERE \"id\" = ? RETURNING *",
            params: [.int(28)]
        )
        #expect(rawFetched == [deletedSecond])
    }

    #expect(try await session.find(FetchRecord.self, deletedSecond.id) == nil)
    #expect(try await session.find(FetchRecord.self, beforeFirst.id) == freshFirst)
    #expect(await state.commits == 1)
    #expect(await state.calls.map(\.scope) == [
        .direct,
        .direct,
        .transaction,
        .transaction,
        .direct,
        .direct,
    ])
}

@Test
func swallowedRawFetchHydrationFailureForcesRollbackAndEvictsBaseIdentity() async throws {
    let before = FetchRecord(id: 29, name: "before", nickname: nil, isActive: true)
    let partial = FetchRecord(id: 29, name: "partial", nickname: nil, isActive: false)
    let fresh = FetchRecord(id: 29, name: "fresh", nickname: nil, isActive: true)
    let malformed = FetchRow(values: [
        "id": .int(30),
        "nickname": .null,
        "is_active": .bool(true),
    ])
    let state = FetchDatabaseState(
        directResponses: [
            .result(ExecResult(rows: [fetchRow(before)])),
            .result(ExecResult(rows: [fetchRow(fresh)])),
        ],
        transactionResponses: [
            .result(ExecResult(rows: [fetchRow(partial), malformed])),
        ]
    )
    let session = Session(database: FetchDatabase(state: state))
    #expect(try await session.find(FetchRecord.self, before.id) == before)

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.fetch(FetchRecord.self, sql: "raw-malformed")
                Issue.record("transactional raw fetch accepted a malformed batch")
            } catch let error as FetchTestError {
                #expect(error == .missingColumn("name"))
            }
        }
        Issue.record("unit of work committed after a swallowed raw hydration failure")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(try await session.find(FetchRecord.self, before.id) == fresh)
    #expect(await state.commits == 0)
    #expect(await state.calls.map(\.scope) == [.direct, .transaction, .direct])
}

@Test
func rawFetchValidatesSchemaBeforeExecutionAndRejectsTransactionControl() async throws {
    let state = FetchDatabaseState()
    let session = Session(database: FetchDatabase(state: state))

    do {
        _ = try await session.fetch(InvalidRawFetchRecord.self, sql: "never-direct")
        Issue.record("direct raw fetch accepted an invalid entity schema")
    } catch let error as EntitySchemaError {
        #expect(error == .duplicateColumn("duplicate"))
    }

    try await session.withUnitOfWork { unitOfWork in
        do {
            _ = try await unitOfWork.fetch(InvalidRawFetchRecord.self, sql: "never-uow")
            Issue.record("transactional raw fetch accepted an invalid entity schema")
        } catch let error as EntitySchemaError {
            #expect(error == .duplicateColumn("duplicate"))
        }
    }

    do {
        let _: Void = try await session.withUnitOfWork { unitOfWork in
            do {
                _ = try await unitOfWork.fetch(
                    FetchRecord.self,
                    sql: "/* guarded */ COMMIT"
                )
                Issue.record("raw fetch accepted transaction control")
            } catch let error as SessionError {
                #expect(error == .transactionControlNotAllowed(command: "COMMIT"))
            }
        }
        Issue.record("unit of work committed after rejected raw transaction control")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkRollbackOnly)
    }

    #expect(await state.calls.isEmpty)
    #expect(await state.commits == 1)
}

private struct FetchRecord: Entity, Equatable {
    typealias PK = Int64

    let id: Int64
    let name: String
    let nickname: String?
    let isActive: Bool

    static let tableName = "fetch\"records"
    static var fields: [FieldDescriptor<FetchRecord>] {
        [
            FieldDescriptor(
                \FetchRecord.id,
                column: "id",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\FetchRecord.name, column: "name"),
            FieldDescriptor(\FetchRecord.nickname, column: "nickname"),
            FieldDescriptor(\FetchRecord.isActive, column: "is_active"),
        ]
    }

    init(id: Int64, name: String, nickname: String?, isActive: Bool) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.isActive = isActive
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
        nickname = try row.decode("nickname", as: String?.self)
        isActive = try row.decode("is_active", as: Bool.self)
    }
}

private struct InvalidRawFetchRecord: Entity {
    typealias PK = Int64

    let id: Int64
    let name: String

    static let tableName = "invalid_raw_fetch"
    static var fields: [FieldDescriptor<InvalidRawFetchRecord>] {
        [
            FieldDescriptor(
                \InvalidRawFetchRecord.id,
                column: "duplicate",
                role: .primaryKey(generated: false)
            ),
            FieldDescriptor(\InvalidRawFetchRecord.name, column: "duplicate"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("duplicate", as: Int64.self)
        name = try row.decode("duplicate", as: String.self)
    }
}

private func fetchRow(_ record: FetchRecord) -> FetchRow {
    FetchRow(values: [
        "id": .int(record.id),
        "name": .text(record.name),
        "nickname": record.nickname.map(SQLValue.text) ?? .null,
        "is_active": .bool(record.isActive),
    ])
}

private func countRow(_ count: Int64) -> FetchRow {
    FetchRow(values: [SQLCount.resultColumn: .int(count)])
}

private struct FetchDatabaseCall: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case direct
        case transaction
    }

    let scope: Scope
    let sql: String
    let parameters: [SQLValue]
}

private enum FetchResponse: Sendable {
    case result(ExecResult)
    case failure(FetchTestError)
}

private actor FetchDatabaseState {
    private var directResponses: [FetchResponse]
    private var transactionResponses: [FetchResponse]
    private let failCommit: Bool
    private(set) var calls: [FetchDatabaseCall] = []
    private(set) var commits = 0

    init(
        directResponses: [FetchResponse] = [],
        transactionResponses: [FetchResponse] = [],
        failCommit: Bool = false
    ) {
        self.directResponses = directResponses
        self.transactionResponses = transactionResponses
        self.failCommit = failCommit
    }

    func execute(
        scope: FetchDatabaseCall.Scope,
        sql: String,
        parameters: [SQLValue]
    ) throws -> ExecResult {
        calls.append(FetchDatabaseCall(scope: scope, sql: sql, parameters: parameters))
        let response: FetchResponse
        switch scope {
        case .direct:
            guard !directResponses.isEmpty else {
                throw FetchTestError.unexpectedExecution
            }
            response = directResponses.removeFirst()
        case .transaction:
            guard !transactionResponses.isEmpty else {
                throw FetchTestError.unexpectedExecution
            }
            response = transactionResponses.removeFirst()
        }
        switch response {
        case let .result(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func commit() throws {
        commits += 1
        if failCommit {
            throw FetchTestError.commitFailed
        }
    }
}

private struct FetchDatabase: Database {
    let state: FetchDatabaseState
    let dialect: any SQLDialect = SQLiteDialect()

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(scope: .direct, sql: sql, parameters: parameters)
    }

    func withTransaction<Value: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> Value
    ) async throws -> Value {
        let value = try await body(FetchTransaction(state: state))
        try await state.commit()
        return value
    }

    func shutdown() async {}
}

private struct FetchTransaction: Transaction {
    let state: FetchDatabaseState

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(scope: .transaction, sql: sql, parameters: parameters)
    }
}

private struct FetchRow: Row {
    let values: [String: SQLValue]

    func decode<Value: SQLValueConvertible>(
        _ column: String,
        as type: Value.Type
    ) throws -> Value {
        guard let value = values[column] else {
            throw FetchTestError.missingColumn(column)
        }
        return try Value(sqlValue: value)
    }

    func decodeIfPresent<Value: SQLValueConvertible>(
        _ column: String,
        as type: Value.Type
    ) throws -> Value? {
        guard let value = values[column] else {
            throw FetchTestError.missingColumn(column)
        }
        guard value != .null else { return nil }
        return try Value(sqlValue: value)
    }
}

private enum FetchTestError: Error, Sendable, Equatable {
    case commitFailed
    case executorFailed
    case missingColumn(String)
    case rollback
    case unexpectedExecution
}

private actor RawConcurrencyState {
    static let rawSQL = "raw-concurrent"

    private let stale: FetchRecord
    private let raw: FetchRecord
    private var findStarted = false
    private var findReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [FetchDatabaseCall] = []

    init(stale: FetchRecord, raw: FetchRecord) {
        self.stale = stale
        self.raw = raw
    }

    func execute(_ sql: String, _ parameters: [SQLValue]) async throws -> ExecResult {
        calls.append(FetchDatabaseCall(scope: .direct, sql: sql, parameters: parameters))
        if sql == Self.rawSQL {
            return ExecResult(rows: [fetchRow(raw)])
        }

        if findStarted {
            guard findReleased else {
                throw FetchTestError.unexpectedExecution
            }
            return ExecResult(rows: [fetchRow(raw)])
        }
        findStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }

        if !findReleased {
            await withCheckedContinuation { continuation in
                if findReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
        return ExecResult(rows: [fetchRow(stale)])
    }

    func waitUntilFindStarted() async {
        guard !findStarted else { return }
        await withCheckedContinuation { continuation in
            if findStarted {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func releaseFind() {
        findReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct RawConcurrencyDatabase: Database {
    let state: RawConcurrencyState
    let dialect: any SQLDialect = SQLiteDialect()

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        try await state.execute(sql, parameters)
    }

    func withTransaction<Value: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> Value
    ) async throws -> Value {
        throw FetchTestError.unexpectedExecution
    }

    func shutdown() async {}
}
