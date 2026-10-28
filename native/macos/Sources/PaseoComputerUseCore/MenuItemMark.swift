import Foundation

/// What the mark character of a menu item says about its state. macOS puts a
/// check mark (or a bullet or diamond for a radio item) in `AXMenuItemMarkChar`
/// when the item is on, and a dash when it is mixed.
public enum MenuItemMark {
    private static let mixedMarks: Set<String> = ["-", "–", "—", "−"]

    /// "checked", "mixed", or nil when the item has no mark.
    public static func state(for mark: String?) -> String? {
        guard let trimmed = mark?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return mixedMarks.contains(trimmed) ? "mixed" : "checked"
    }
}
