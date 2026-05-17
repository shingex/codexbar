import Foundation

enum CompatibleProviderUseExecutor {
    static func execute(
        activate: () throws -> Void
    ) async throws {
        try activate()
    }
}
