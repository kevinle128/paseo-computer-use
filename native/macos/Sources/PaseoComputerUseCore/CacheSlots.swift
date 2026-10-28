import Foundation

/// One cached value per process. A read the agent did not ask for stores
/// nothing (`replace: false`), so it can never change which elements and which
/// window the agent's own last read bound.
struct CacheSlots<Value> {
    private var slots: [pid_t: Value] = [:]

    subscript(pid: pid_t) -> Value? {
        get { slots[pid] }
        set { slots[pid] = newValue }
    }

    mutating func store(_ value: Value, for pid: pid_t, replace: Bool) {
        if replace {
            slots[pid] = value
        }
    }
}
