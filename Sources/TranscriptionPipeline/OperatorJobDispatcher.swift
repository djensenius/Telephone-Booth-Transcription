import TranscriptionShared

/// Executes a synthetic Operator job and produces its local result.
public protocol OperatorJobDispatcher: Sendable {
    func execute(job: OperatorJob) async throws -> OperatorJobResult
}
