@testable import PerunMigrations
import PerunDBAL
import Testing

@Test
func migrationContextDelegatesStatementParametersIntentAndResult() async throws {
    let expectedResult = ExecResult(rowsAffected: 3, lastInsertRowID: 41)
    let executor = ContextRecordingExecutor(response: .success(expectedResult))
    let context = context(using: executor)

    let result = try await context.execute(
        "INSERT INTO widgets (id) VALUES (:1)",
        [.int(7)],
        intent: .generatedRowIDInsert
    )

    #expect(result.rows.isEmpty)
    #expect(result.rowsAffected == 3)
    #expect(result.lastInsertRowID == 41)
    #expect(
        await executor.recordedCalls() == [
            ContextExecutionCall(
                sql: "INSERT INTO widgets (id) VALUES (:1)",
                parameters: [.int(7)],
                intent: .generatedRowIDInsert
            ),
        ]
    )
    try await context.close()
}

@Test
func migrationContextRejectsTransactionControlBeforeCallingExecutor() async {
    let executor = ContextRecordingExecutor(response: .success(ExecResult()))
    let context = context(using: executor)

    await expectContextError(.transactionControlNotAllowed(command: "COMMIT")) {
        try await context.execute(
            " /* migration boundary */ COMMIT",
            [],
            intent: .arbitrary
        )
    }

    #expect(await executor.recordedCalls().isEmpty)
    await expectContextError(.contextRollbackOnly) {
        try await context.execute("SELECT 1", [], intent: .arbitrary)
    }
    await expectContextError(.contextRollbackOnly) {
        try await context.close()
    }
}

@Test
func migrationContextRejectsBOMPrefixedTransactionControlBeforeCallingExecutor() async {
    let executor = ContextRecordingExecutor(response: .success(ExecResult()))
    let context = context(using: executor)

    await expectContextError(.transactionControlNotAllowed(command: "COMMIT")) {
        try await context.execute("\u{FEFF}COMMIT", [], intent: .arbitrary)
    }

    #expect(await executor.recordedCalls().isEmpty)
    await expectContextError(.contextRollbackOnly) {
        try await context.close()
    }
}

@Test
func migrationContextGivesLeadingControlPrecedenceOverBatchValidation() async {
    let executor = ContextRecordingExecutor(response: .success(ExecResult()))
    let context = context(using: executor)

    await expectContextError(.transactionControlNotAllowed(command: "COMMIT")) {
        try await context.execute(
            "COMMIT; SELECT 1",
            [],
            intent: .arbitrary
        )
    }

    #expect(await executor.recordedCalls().isEmpty)
}

@Test
func migrationContextPassesSafeBatchToExecutorAndPreservesItsError() async {
    let executor = ContextRecordingExecutor(response: .failure(.statementRejected))
    let context = context(using: executor)

    do {
        _ = try await context.execute(
            "SELECT 1; SELECT 2",
            [],
            intent: .arbitrary
        )
        Issue.record("a multi-statement batch unexpectedly succeeded")
    } catch let error as ContextSentinelError {
        #expect(error == .statementRejected)
    } catch {
        Issue.record("the executor error was wrapped as \(error)")
    }

    #expect(
        await executor.recordedCalls() == [
            ContextExecutionCall(
                sql: "SELECT 1; SELECT 2",
                parameters: [],
                intent: .arbitrary
            ),
        ]
    )
    await expectContextError(.contextRollbackOnly) {
        try await context.execute("SELECT 3", [], intent: .arbitrary)
    }
    await expectContextError(.contextRollbackOnly) {
        try await context.close()
    }
}

@Test
func migrationContextPassesTrailingControlBatchToExecutor() async {
    let executor = ContextRecordingExecutor(response: .failure(.statementRejected))
    let context = context(using: executor)

    do {
        _ = try await context.execute(
            "SELECT 1; COMMIT",
            [],
            intent: .arbitrary
        )
        Issue.record("a trailing transaction-control batch unexpectedly succeeded")
    } catch let error as ContextSentinelError {
        #expect(error == .statementRejected)
    } catch {
        Issue.record("the executor batch error was wrapped as \(error)")
    }

    #expect(await executor.recordedCalls().map(\.sql) == ["SELECT 1; COMMIT"])
}

@Test
func overlappingMigrationContextExecutionIsRejectedBeforeSecondExecutorCall() async throws {
    let executor = ContextBlockingExecutor()
    let context = context(using: executor)
    let firstExecution = Task {
        try await context.execute("SELECT first", [], intent: .arbitrary)
    }

    await executor.waitUntilEntered()
    await expectContextError(.contextBusy) {
        try await context.execute("SELECT second", [], intent: .arbitrary)
    }
    #expect(
        await executor.recordedCalls() == [
            ContextExecutionCall(
                sql: "SELECT first",
                parameters: [],
                intent: .arbitrary
            ),
        ]
    )

    await executor.release()
    _ = try await firstExecution.value
    await expectContextError(.contextRollbackOnly) {
        try await context.close()
    }
}

@Test
func closingMigrationContextWaitsForActiveOperationAndReportsEscape() async throws {
    let events = ContextEventLog()
    let executor = ContextBlockingExecutor(events: events)
    let context = context(using: executor)
    let execution = Task {
        try await context.execute("SELECT blocked", [], intent: .arbitrary)
    }
    await executor.waitUntilEntered()

    let closing = Task { () -> MigrationExecutionError? in
        let outcome: MigrationExecutionError?
        do {
            try await context.close()
            outcome = nil
        } catch let error as MigrationExecutionError {
            outcome = error
        } catch {
            Issue.record("close returned an unexpected error: \(error)")
            outcome = nil
        }
        await events.record(.closeReturned)
        return outcome
    }

    await waitUntilContextRejectsAsClosed(context)
    await executor.release()
    _ = try await execution.value

    #expect(await closing.value == .contextOperationEscaped)
    #expect(
        await events.recordedEvents() == [
            .operationStarted,
            .operationFinished,
            .closeReturned,
        ]
    )
    #expect(await executor.recordedCalls().count == 1)
}

@Test
func copiedMigrationContextsShareOneLifecycle() async throws {
    let executor = ContextRecordingExecutor(response: .success(ExecResult()))
    let original = context(using: executor)
    let copy = original

    _ = try await copy.execute("SELECT 1", [], intent: .arbitrary)
    try await original.close()
    try await copy.close()

    await expectContextError(.contextClosed) {
        try await copy.execute("SELECT 2", [], intent: .arbitrary)
    }
    #expect(await executor.recordedCalls().map(\.sql) == ["SELECT 1"])
}

@Test
func delayedMigrationContextUseIsClosedWithoutCallingExecutor() async throws {
    let start = ContextGate()
    let executor = ContextRecordingExecutor(response: .success(ExecResult()))
    let context = context(using: executor)
    let retainedCopy = context
    let delayedExecution = Task {
        await start.wait()
        return try await retainedCopy.execute("SELECT delayed", [], intent: .arbitrary)
    }

    try await context.close()
    await start.open()

    do {
        _ = try await delayedExecution.value
        Issue.record("delayed context use unexpectedly succeeded")
    } catch let error as MigrationExecutionError {
        #expect(error == .contextClosed)
    } catch {
        Issue.record("delayed context use returned an unexpected error: \(error)")
    }
    #expect(await executor.recordedCalls().isEmpty)
}

private func context(using executor: ContextRecordingExecutor) -> MigrationContext {
    MigrationContext(dialect: ContextTestDialect()) { sql, parameters, intent in
        try await executor.execute(sql, parameters, intent: intent)
    }
}

private func context(using executor: ContextBlockingExecutor) -> MigrationContext {
    MigrationContext(dialect: ContextTestDialect()) { sql, parameters, intent in
        await executor.execute(sql, parameters, intent: intent)
    }
}

private func expectContextError<T: Sendable>(
    _ expected: MigrationExecutionError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("operation unexpectedly succeeded instead of throwing \(expected)")
    } catch let error as MigrationExecutionError {
        #expect(error == expected)
    } catch {
        Issue.record("operation returned an unexpected error: \(error)")
    }
}

private func waitUntilContextRejectsAsClosed(_ context: MigrationContext) async {
    for _ in 0 ..< 10_000 {
        do {
            _ = try await context.execute("SELECT late", [], intent: .arbitrary)
            Issue.record("late execution unexpectedly reached the executor")
            return
        } catch let error as MigrationExecutionError {
            switch error {
            case .contextClosed:
                return
            case .contextBusy, .contextRollbackOnly:
                await Task.yield()
            default:
                Issue.record("late execution returned an unexpected lifecycle error: \(error)")
                return
            }
        } catch {
            Issue.record("late execution returned an unexpected error: \(error)")
            return
        }
    }
    Issue.record("close did not transition the context out of open state")
}

private struct ContextTestDialect: SQLDialect {
    let capabilities: DialectCapabilities = []

    func placeholder(at position: Int) -> String {
        precondition(position > 0)
        return ":\(position)"
    }
}

private struct ContextExecutionCall: Sendable, Equatable {
    let sql: String
    let parameters: [SQLValue]
    let intent: ExecutionIntent
}

private enum ContextExecutionResponse: Sendable {
    case success(ExecResult)
    case failure(ContextSentinelError)
}

private actor ContextRecordingExecutor {
    private var calls: [ContextExecutionCall] = []
    private let response: ContextExecutionResponse

    init(response: ContextExecutionResponse) {
        self.response = response
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) throws -> ExecResult {
        calls.append(ContextExecutionCall(sql: sql, parameters: parameters, intent: intent))
        switch response {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func recordedCalls() -> [ContextExecutionCall] {
        calls
    }
}

private actor ContextBlockingExecutor {
    private let entered = ContextGate()
    private let releaseGate = ContextGate()
    private let events: ContextEventLog?
    private var calls: [ContextExecutionCall] = []

    init(events: ContextEventLog? = nil) {
        self.events = events
    }

    func execute(
        _ sql: String,
        _ parameters: [SQLValue],
        intent: ExecutionIntent
    ) async -> ExecResult {
        calls.append(ContextExecutionCall(sql: sql, parameters: parameters, intent: intent))
        await events?.record(.operationStarted)
        await entered.open()
        await releaseGate.wait()
        await events?.record(.operationFinished)
        return ExecResult()
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func release() async {
        await releaseGate.open()
    }

    func recordedCalls() -> [ContextExecutionCall] {
        calls
    }
}

private actor ContextGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
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
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private enum ContextEvent: Sendable, Equatable {
    case operationStarted
    case operationFinished
    case closeReturned
}

private actor ContextEventLog {
    private var events: [ContextEvent] = []

    func record(_ event: ContextEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ContextEvent] {
        events
    }
}

private enum ContextSentinelError: Error, Sendable, Equatable {
    case statementRejected
}
