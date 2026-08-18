import PerunDBAL
import PerunORM
import Testing

@Test
func entitySchemaDerivesOneValidatedPrimaryKey() throws {
    let schema = try EntitySchema(User.self)

    #expect(schema.tableName == "users")
    #expect(schema.fields.count == 2)
    #expect(schema.primaryKey.column == "id")
    #expect(User.field(for: \User.name)?.column == "name")
}

@Test
func entitySchemaRejectsAnOptionalPrimaryKey() {
    #expect(throws: EntitySchemaError.nullablePrimaryKey("id")) {
        try EntitySchema(InvalidUser.self)
    }
    #expect(throws: EntitySchemaError.nullablePrimaryKey("id")) {
        try EntitySchema(OptionalPrimaryKeyAlias.self)
    }
}

@Test
func entitySchemaRejectsUnstableAndInvalidGeneratedPrimaryKeys() {
    #expect(throws: EntitySchemaError.unsupportedPrimaryKeyType(.double)) {
        try EntitySchema(DoubleKeyEntity.self)
    }
    #expect(
        throws: EntitySchemaError.generatedPrimaryKeyRequiresInt64(
            column: "id",
            actual: .text
        )
    ) {
        try EntitySchema(GeneratedStringKeyEntity.self)
    }
}

@Test
func entitySchemaRejectsCaseInsensitiveColumnCollisions() {
    #expect(throws: EntitySchemaError.duplicateColumn("ID")) {
        try EntitySchema(CaseCollidingEntity.self)
    }
}

@Test
func entitySchemaRejectsDuplicateKeyPaths() {
    #expect(throws: EntitySchemaError.duplicateKeyPath(column: "legacy_id")) {
        try EntitySchema(DuplicateKeyPathEntity.self)
    }
}

@Test
func unitOfWorkOwnsTheTransactionAndClosesAfterTheBody() async throws {
    let recorder = Recorder()
    let session = Session(database: FakeDatabase(recorder: recorder))
    let query = try Query(User.self)

    let escapedUnitOfWork = try await session.withUnitOfWork { unitOfWork in
        _ = try await unitOfWork.execute("inside", [.int(1)])

        do {
            _ = try await session.execute("outside")
            Issue.record("session execution unexpectedly entered an active unit of work")
        } catch let error as SessionError {
            #expect(error == .sessionBusy)
        }

        do {
            _ = try await session.find(User.self, 1)
            Issue.record("session find unexpectedly entered an active unit of work")
        } catch let error as SessionError {
            #expect(error == .sessionBusy)
        }

        do {
            _ = try await session.fetch(query)
            Issue.record("session fetch unexpectedly entered an active unit of work")
        } catch let error as SessionError {
            #expect(error == .sessionBusy)
        }

        return unitOfWork
    }

    do {
        _ = try await escapedUnitOfWork.execute("escaped")
        Issue.record("escaped unit of work remained usable")
    } catch let error as SessionError {
        #expect(error == .unitOfWorkClosed)
    }

    #expect(await recorder.statements == ["inside"])
}

@Test
func unitOfWorkRejectsOverlapAndWaitsForAnOperationThatAlreadyStarted() async throws {
    let gate = OperationGate()
    let recorder = Recorder()
    let unitOfWorkBox = UnitOfWorkBox()
    let session = Session(database: GatedDatabase(gate: gate, recorder: recorder))

    let transaction = Task {
        try await session.withUnitOfWork { unitOfWork in
            await unitOfWorkBox.store(unitOfWork)
            let operation = Task {
                try await unitOfWork.execute("slow")
            }
            await gate.waitUntilStarted()

            do {
                _ = try await unitOfWork.execute("overlap")
                Issue.record("unit of work unexpectedly ran concurrent operations")
            } catch let error as SessionError {
                #expect(error == .unitOfWorkBusy)
            }

            return operation
        }
    }

    let escapedUnitOfWork = await unitOfWorkBox.get()
    await gate.waitUntilStarted()

    // Synchronize on the lifecycle transition itself; the deadline only bounds regressions.
    try await waitUntilUnitOfWorkCloses(escapedUnitOfWork, releasingOnTimeout: gate)

    await gate.release()
    let operation = try await transaction.value
    _ = try await operation.value
    #expect(await recorder.statements == ["transaction-start", "transaction-finish", "commit"])
}

@Test
func unitOfWorkCannotStartWhileADirectSessionOperationIsInFlight() async throws {
    let gate = OperationGate()
    let recorder = Recorder()
    let session = Session(database: GatedDatabase(gate: gate, recorder: recorder))
    let directOperation = Task {
        try await session.execute("direct")
    }

    await gate.waitUntilStarted()
    do {
        let _: Void = try await session.withUnitOfWork { _ in }
        Issue.record("unit of work unexpectedly overlapped a direct session operation")
    } catch let error as SessionError {
        #expect(error == .sessionBusy)
    }

    await gate.release()
    _ = try await directOperation.value
    #expect(await recorder.statements == ["direct-start", "direct-finish"])
}

@Test
func unitOfWorkCannotStartWhileSessionFindIsInFlight() async throws {
    let gate = OperationGate()
    let recorder = Recorder()
    let session = Session(database: GatedDatabase(gate: gate, recorder: recorder))
    let findOperation = Task {
        try await session.find(User.self, 1)
    }

    await gate.waitUntilStarted()
    do {
        let _: Void = try await session.withUnitOfWork { _ in }
        Issue.record("unit of work unexpectedly overlapped session find")
    } catch let error as SessionError {
        #expect(error == .sessionBusy)
    }

    await gate.release()
    let found = try await findOperation.value
    #expect(found == nil)
    #expect(await recorder.statements == ["direct-start", "direct-finish"])
}

@Test
func operationGateReleasesWaitersWhenTheirTaskIsCancelled() async {
    let gate = OperationGate()
    let waiter = Task {
        await gate.startAndWaitForRelease()
    }

    await gate.waitUntilStarted()
    waiter.cancel()
    await waiter.value
}

private struct User: Entity {
    typealias PK = Int64

    let id: Int64
    let name: String

    static let tableName = "users"
    static var fields: [FieldDescriptor<User>] {
        [
            FieldDescriptor(\User.id, column: "id", role: .primaryKey(generated: true)),
            FieldDescriptor(\User.name, column: "name"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        name = try row.decode("name", as: String.self)
    }
}

private struct InvalidUser: Entity {
    typealias PK = Int64?

    let id: Int64?

    static let tableName = "invalid_users"
    static var fields: [FieldDescriptor<InvalidUser>] {
        [
            FieldDescriptor(\InvalidUser.id, column: "id", role: .primaryKey(generated: true)),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64?.self)
    }
}

private struct OptionalPrimaryKeyAlias: Entity {
    typealias PK = Int64?

    let id: Int64

    static let tableName = "optional_primary_key_aliases"
    static var fields: [FieldDescriptor<OptionalPrimaryKeyAlias>] {
        [FieldDescriptor(\OptionalPrimaryKeyAlias.id, column: "id", role: .primaryKey(generated: true))]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
    }
}

private struct DoubleKeyEntity: Entity {
    typealias PK = Double

    let id: Double

    static let tableName = "double_keys"
    static var fields: [FieldDescriptor<DoubleKeyEntity>] {
        [FieldDescriptor(\DoubleKeyEntity.id, column: "id", role: .primaryKey(generated: false))]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Double.self)
    }
}

private struct GeneratedStringKeyEntity: Entity {
    typealias PK = String

    let id: String

    static let tableName = "generated_string_keys"
    static var fields: [FieldDescriptor<GeneratedStringKeyEntity>] {
        [FieldDescriptor(\GeneratedStringKeyEntity.id, column: "id", role: .primaryKey(generated: true))]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: String.self)
    }
}

private struct CaseCollidingEntity: Entity {
    typealias PK = Int64

    let id: Int64
    let duplicate: String

    static let tableName = "case_collisions"
    static var fields: [FieldDescriptor<CaseCollidingEntity>] {
        [
            FieldDescriptor(\CaseCollidingEntity.id, column: "id", role: .primaryKey(generated: true)),
            FieldDescriptor(\CaseCollidingEntity.duplicate, column: "ID"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
        duplicate = try row.decode("ID", as: String.self)
    }
}

private struct DuplicateKeyPathEntity: Entity {
    typealias PK = Int64

    let id: Int64

    static let tableName = "duplicate_key_paths"
    static var fields: [FieldDescriptor<DuplicateKeyPathEntity>] {
        [
            FieldDescriptor(\DuplicateKeyPathEntity.id, column: "id", role: .primaryKey(generated: true)),
            FieldDescriptor(\DuplicateKeyPathEntity.id, column: "legacy_id"),
        ]
    }

    init(row: any Row) throws {
        id = try row.decode("id", as: Int64.self)
    }
}

private struct FakeDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String { "?" }
}

private actor Recorder {
    private(set) var statements: [String] = []

    func record(_ sql: String) {
        statements.append(sql)
    }
}

private actor OperationGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func startAndWaitForRelease() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }

        guard !isReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelAllWaiters() }
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasStarted {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelAllWaiters() }
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelAllWaiters() {
        hasStarted = true
        isReleased = true

        let waitingForStart = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waitingForStart {
            waiter.resume()
        }

        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waitingForRelease {
            waiter.resume()
        }
    }
}

private actor UnitOfWorkBox {
    private var value: UnitOfWork?
    private var waiter: CheckedContinuation<UnitOfWork, Never>?

    func store(_ value: UnitOfWork) {
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func get() async -> UnitOfWork {
        if let value {
            return value
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private enum LifecycleProbeError: Error {
    case acceptedWork
    case timedOut
}

private func waitUntilUnitOfWorkCloses(
    _ unitOfWork: UnitOfWork,
    releasingOnTimeout gate: OperationGate
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while true {
                try Task.checkCancellation()
                do {
                    _ = try await unitOfWork.execute("after-body")
                    throw LifecycleProbeError.acceptedWork
                } catch SessionError.unitOfWorkBusy {
                    await Task.yield()
                } catch SessionError.unitOfWorkClosed {
                    return
                }
            }
        }
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                await gate.release()
                throw error
            }
            await gate.release()
            throw LifecycleProbeError.timedOut
        }

        defer { group.cancelAll() }
        _ = try await group.next()
    }
}

private struct FakeTransaction: Transaction {
    let recorder: Recorder

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await recorder.record(sql)
        return ExecResult(rowsAffected: 0)
    }
}

private struct FakeDatabase: Database {
    let recorder: Recorder
    var dialect: any SQLDialect { FakeDialect() }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await recorder.record(sql)
        return ExecResult(rowsAffected: 0)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        try await body(FakeTransaction(recorder: recorder))
    }

    func shutdown() async {}
}

private struct GatedTransaction: Transaction {
    let gate: OperationGate
    let recorder: Recorder

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await recorder.record("transaction-start")
        await gate.startAndWaitForRelease()
        await recorder.record("transaction-finish")
        return ExecResult(rowsAffected: 0)
    }
}

private struct GatedDatabase: Database {
    let gate: OperationGate
    let recorder: Recorder
    var dialect: any SQLDialect { FakeDialect() }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async throws -> ExecResult {
        await recorder.record("direct-start")
        await gate.startAndWaitForRelease()
        await recorder.record("direct-finish")
        return ExecResult(rowsAffected: 0)
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable (any Transaction) async throws -> T
    ) async throws -> T {
        let result = try await body(GatedTransaction(gate: gate, recorder: recorder))
        await recorder.record("commit")
        return result
    }

    func shutdown() async {}
}
