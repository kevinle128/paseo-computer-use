import Foundation

/// Which close button stands for Command+w in a window that could not be made
/// the app's key window.
///
/// Command+w closes one tab in a window with tabs (Chrome, Safari, Terminal,
/// Finder, VS Code, and every app with native window tabs), but the window's
/// close button closes all of them, and Chrome does not ask. So the window's
/// close button is used only when the window has no tab bar or a single tab.
/// With more tabs, the selected tab's own close button is pressed, and when no
/// single such button can be found, nothing is pressed.
///
/// The decision has no accessibility call of its own: `Tree` reads the
/// elements, so tests drive it with fake trees.
public enum CloseControl<Node> {
    /// The window has no tab bar, or one tab: its own close button.
    case window
    /// The close button of the selected tab.
    case tab(button: Node)
    /// Command+w would close one tab and no single button does only that, or
    /// the window was too large to read within the limits.
    case refuse

    /// How the decision reads an element.
    public struct Tree {
        public var role: (Node) -> String?
        public var subrole: (Node) -> String?
        /// The title and the description, for the name of a button.
        public var names: (Node) -> [String]
        /// Whether a tab is the selected one (AXValue 1 or AXSelected).
        public var isSelected: (Node) -> Bool
        public var children: (Node) -> [Node]

        public init(
            role: @escaping (Node) -> String?,
            subrole: @escaping (Node) -> String?,
            names: @escaping (Node) -> [String],
            isSelected: @escaping (Node) -> Bool,
            children: @escaping (Node) -> [Node]
        ) {
            self.role = role
            self.subrole = subrole
            self.names = names
            self.isSelected = isSelected
            self.children = children
        }
    }

    /// The most elements one decision reads. A browser's own interface is a
    /// few hundred; a larger window is refused rather than half read.
    public static var maxNodes: Int { 2_000 }

    /// Button names of a tab's close button, compared without case.
    static var closeButtonNames: Set<String> { ["close", "close tab"] }

    /// Decides what Command+w closes in `window`.
    ///
    /// The window is read without its web areas first: a browser's tab strip
    /// is part of its own interface, and a tab list inside a page does not
    /// change what Command+w closes. Only when that finds no tab bar are the
    /// web areas read, because an Electron app (VS Code) draws its tabs in
    /// one. `checkpoint` runs before each element is read, so a cancel or a
    /// time limit can stop the walk; its error is passed on.
    public static func decide(
        window: Node,
        tree: Tree,
        maxNodes: Int = maxNodes,
        checkpoint: () throws -> Void
    ) rethrows -> CloseControl {
        var budget = maxNodes
        let native = try collectTabBars(from: [window], tree: tree, skipWebAreas: true, budget: &budget, checkpoint: checkpoint)
        guard native.complete else { return .refuse }
        if !native.bars.isEmpty {
            return try choose(bars: native.bars, tree: tree, budget: &budget, checkpoint: checkpoint)
        }
        let web = try collectTabBars(from: native.webAreas, tree: tree, skipWebAreas: false, budget: &budget, checkpoint: checkpoint)
        guard web.complete else { return .refuse }
        return try choose(bars: web.bars, tree: tree, budget: &budget, checkpoint: checkpoint)
    }

    private struct Collected {
        var bars: [(bar: Node, children: [Node])] = []
        var webAreas: [Node] = []
        var complete = true
    }

    /// Finds the tab bars under `roots`, breadth first: an `AXTabGroup`, or
    /// an element with a child of subrole `AXTabButton`. A tab bar is not
    /// searched for more tab bars.
    private static func collectTabBars(
        from roots: [Node],
        tree: Tree,
        skipWebAreas: Bool,
        budget: inout Int,
        checkpoint: () throws -> Void
    ) rethrows -> Collected {
        var found = Collected()
        var queue = roots
        var index = 0
        while index < queue.count {
            let node = queue[index]
            index += 1
            guard budget > 0 else {
                found.complete = false
                return found
            }
            budget -= 1
            try checkpoint()
            let role = tree.role(node)
            if skipWebAreas && role == "AXWebArea" {
                found.webAreas.append(node)
                continue
            }
            try checkpoint()
            let children = tree.children(node)
            var isTabBar = role == "AXTabGroup"
            if !isTabBar {
                isTabBar = try children.contains { child in
                    try checkpoint()
                    return tree.subrole(child) == "AXTabButton"
                }
            }
            if isTabBar {
                found.bars.append((node, children))
            } else {
                queue.append(contentsOf: children)
            }
        }
        return found
    }

    private static func choose(
        bars: [(bar: Node, children: [Node])],
        tree: Tree,
        budget: inout Int,
        checkpoint: () throws -> Void
    ) rethrows -> CloseControl {
        var candidates: [Node] = []
        var anyBarWithTabs = false
        for entry in bars {
            // A tab is a radio button or a tab button of the bar. A tab list
            // nested in the bar, or a page inside it, is not searched.
            guard let tabs = try descendants(
                of: entry.children, tree: tree, budget: &budget, checkpoint: checkpoint,
                matches: { role, node in
                    if role == "AXRadioButton" { return true }
                    try checkpoint()
                    return tree.subrole(node) == "AXTabButton"
                },
                descendsInto: { role in role != "AXTabGroup" && role != "AXWebArea" }
            ) else { return .refuse }
            guard tabs.count > 1 else { continue }
            anyBarWithTabs = true
            var selected: [Node] = []
            for tab in tabs {
                try checkpoint()
                if tree.isSelected(tab) { selected.append(tab) }
            }
            guard selected.count == 1 else { continue }
            try checkpoint()
            guard let buttons = try descendants(
                of: tree.children(selected[0]), tree: tree, budget: &budget, checkpoint: checkpoint,
                matches: { role, node in
                    guard role == "AXButton" else { return false }
                    try checkpoint()
                    return tree.names(node).contains {
                        closeButtonNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                    }
                },
                descendsInto: { _ in true }
            ) else { return .refuse }
            if buttons.count == 1 { candidates.append(buttons[0]) }
        }
        guard anyBarWithTabs else { return .window }
        return candidates.count == 1 ? .tab(button: candidates[0]) : .refuse
    }

    /// The elements under `roots` (roots included) that match, without
    /// searching inside a match or inside an element whose role
    /// `descendsInto` refuses. Nil when the budget runs out.
    private static func descendants(
        of roots: [Node],
        tree: Tree,
        budget: inout Int,
        checkpoint: () throws -> Void,
        matches: (_ role: String?, _ node: Node) throws -> Bool,
        descendsInto: (_ role: String?) -> Bool
    ) rethrows -> [Node]? {
        var result: [Node] = []
        var queue = roots
        var index = 0
        while index < queue.count {
            let node = queue[index]
            index += 1
            guard budget > 0 else { return nil }
            budget -= 1
            try checkpoint()
            let role = tree.role(node)
            if try matches(role, node) {
                result.append(node)
                continue
            }
            guard descendsInto(role) else { continue }
            try checkpoint()
            queue.append(contentsOf: tree.children(node))
        }
        return result
    }
}
