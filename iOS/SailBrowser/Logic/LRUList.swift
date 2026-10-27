nonisolated struct LRUList<Key: Hashable & Sendable>: Sendable {
    private let capacity: Int
    private(set) var keys: [Key] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func touch(_ key: Key) -> [Key] {
        remove(key)
        keys.append(key)
        return evict(keeping: max(capacity, 1))
    }

    mutating func remove(_ key: Key) {
        keys.removeAll { $0 == key }
    }

    mutating func shrink(to capacity: Int) -> [Key] {
        evict(keeping: capacity)
    }

    private mutating func evict(keeping count: Int) -> [Key] {
        let excess = keys.count - count
        guard excess > 0 else { return [] }
        defer { keys.removeFirst(excess) }
        return Array(keys.prefix(excess))
    }
}
