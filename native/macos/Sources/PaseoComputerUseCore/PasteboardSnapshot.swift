import AppKit
import Foundation

/// Every item on a pasteboard with the data of every type it holds. Pasting
/// replaces the user's clipboard for a moment; this puts back images, files,
/// rich text, and multiple items, not only plain text.
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// One array of entries per pasteboard item. Empty when the pasteboard
    /// held nothing.
    public let items: [[Entry]]

    public init(items: [[Entry]]) {
        self.items = items
    }

    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> Entry? in
                guard let data = item.data(forType: type) else { return nil }
                return Entry(type: type.rawValue, data: data)
            }
        }
        return PasteboardSnapshot(items: items.filter { !$0.isEmpty })
    }

    /// Writes the snapshot back. An empty snapshot leaves the pasteboard
    /// empty, so pasted text never stays on a clipboard that held nothing.
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
