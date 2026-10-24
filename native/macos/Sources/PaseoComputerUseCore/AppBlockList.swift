import Foundation

/// Apps Computer Use must never read or control. The plugin owns the list
/// (built-in password managers plus the user's extra bundle ids) and sends it
/// with every app command, so the helper and the plugin check one list.
public struct AppBlockList: Sendable, Equatable {
    public static let parameterName = "blockedBundleIds"

    private let lowercasedIds: Set<String>

    public init<S: Sequence>(bundleIds: S) where S.Element == String {
        lowercasedIds = Set(
            bundleIds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// Reads the list from a command's parameters. A command without the
    /// list is refused: a caller that forgets it must not unblock every app.
    public init(params: [String: Any]) throws {
        guard let ids = params[Self.parameterName] as? [String] else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "Missing '\(Self.parameterName)' parameter."
            )
        }
        self.init(bundleIds: ids)
    }

    public func blocks(_ identifier: String) -> Bool {
        lowercasedIds.contains(identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public func check(_ identifier: String) throws {
        if blocks(identifier) {
            throw HelperError(
                code: HelperError.appBlocked,
                message: "Computer Use is not allowed to use the app '\(identifier)' for safety reasons."
            )
        }
    }
}
