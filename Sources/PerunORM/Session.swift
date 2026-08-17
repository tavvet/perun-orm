import Foundation
import PerunDBAL

public enum SessionError: Error, Sendable, Equatable {
    case sessionBusy
    case unitOfWorkBusy
    case unitOfWorkClosed
}

private struct EntityKey: Sendable, Hashable {
    let type: ObjectIdentifier
    let primaryKey: SQLValue
}

/// Actor-isolated ORM state. Database operations inside a transaction are exposed only by UoW.
public actor Session {
    private let database: any Database
    private var identity: [EntityKey: any Entity] = [:]
    private var activeUnitOfWork: UUID?
    private var activeDatabaseOperations = 0

    public init(database: any Database) {
        self.database = database
    }

    /// A raw execution seam used by the compile spike and future query façade.
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        guard activeUnitOfWork == nil else {
            throw SessionError.sessionBusy
        }
        activeDatabaseOperations += 1
        defer { activeDatabaseOperations -= 1 }
        return try await database.execute(sql, parameters)
    }

    public func withUnitOfWork<T: Sendable>(
        _ body: @Sendable (UnitOfWork) async throws -> T
    ) async throws -> T {
        guard activeUnitOfWork == nil, activeDatabaseOperations == 0 else {
            throw SessionError.sessionBusy
        }

        let token = UUID()
        activeUnitOfWork = token
        defer {
            precondition(activeUnitOfWork == token)
            activeUnitOfWork = nil
        }

        return try await database.withTransaction { transaction in
            let unitOfWork = UnitOfWork(transaction: transaction)
            do {
                let result = try await body(unitOfWork)
                await unitOfWork.close()
                return result
            } catch {
                await unitOfWork.close()
                throw error
            }
        }
    }
}

/// The scoped transactional executor. Snapshot overlays are added with CRUD in the next slice.
public actor UnitOfWork {
    private enum Lifecycle: Equatable {
        case open
        case closing
        case closed
    }

    private let transaction: any Transaction
    private var lifecycle = Lifecycle.open
    private var inFlightOperations = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(transaction: any Transaction) {
        self.transaction = transaction
    }

    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> ExecResult {
        guard lifecycle == .open else {
            throw SessionError.unitOfWorkClosed
        }
        guard inFlightOperations == 0 else {
            throw SessionError.unitOfWorkBusy
        }
        inFlightOperations += 1
        defer {
            inFlightOperations -= 1
            if lifecycle == .closing, inFlightOperations == 0 {
                finishClosing()
            }
        }
        return try await transaction.execute(sql, parameters)
    }

    func close() async {
        switch lifecycle {
        case .open:
            lifecycle = .closing
            if inFlightOperations == 0 {
                finishClosing()
                return
            }
        case .closing:
            break
        case .closed:
            return
        }

        await withCheckedContinuation { continuation in
            if lifecycle == .closed {
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
            }
        }
    }

    private func finishClosing() {
        lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
