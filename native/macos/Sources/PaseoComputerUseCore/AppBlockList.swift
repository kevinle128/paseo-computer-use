import Foundation

/// Apps Computer Use must never read or control. The plugin owns the list
/// (built-in password managers plus the user's extra bundle ids) and sends it
/// with every app command, so the helper and the plugin check one list.
public struct AppBlockList: Sendable, Equatable {
    public static let parameterName = "blockedBundleIds"
    /// Optional bundle id prefixes, for apps whose ids differ per install
    /// (for example `com.google.Chrome.app.` web apps). A command without
    /// them blocks no prefix.
    public static let prefixParameterName = "blockedBundleIdPrefixes"

    private let lowercasedIds: Set<String>
    private let lowercasedPrefixes: Set<String>

    public init<S: Sequence, P: Sequence>(bundleIds: S, prefixes: P)
    where S.Element == String, P.Element == String {
        lowercasedIds = Self.normalized(bundleIds)
        lowercasedPrefixes = Self.normalized(prefixes)
    }

    public init<S: Sequence>(bundleIds: S) where S.Element == String {
        self.init(bundleIds: bundleIds, prefixes: [String]())
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
        let prefixes: [String]
        switch params[Self.prefixParameterName] {
        case nil:
            prefixes = []
        case let value as [String]:
            prefixes = value
        default:
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "'\(Self.prefixParameterName)' must be a list of strings."
            )
        }
        self.init(bundleIds: ids, prefixes: prefixes)
    }

    public func blocks(_ identifier: String) -> Bool {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowercasedIds.contains(id) { return true }
        return lowercasedPrefixes.contains { id.hasPrefix($0) }
    }

    /// Refuses a blocked app. The error carries the refused bundle id as
    /// `bundleId`, so the plugin can tell which rule refused it.
    public func check(_ identifier: String) throws {
        if blocks(identifier) {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError(
                code: HelperError.appBlocked,
                message: "Computer Use is not allowed to use the app '\(trimmed)' for safety reasons.",
                bundleId: trimmed
            )
        }
    }

    private static func normalized<S: Sequence>(_ values: S) -> Set<String> where S.Element == String {
        Set(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
