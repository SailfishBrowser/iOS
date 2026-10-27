import Testing
@testable import SailBrowser

struct LRUListTests {
    @Test func touchEvictsLeastRecentFirst() {
        var list = LRUList<String>(capacity: 3)
        #expect(list.touch("a") == [])
        #expect(list.touch("b") == [])
        #expect(list.touch("c") == [])
        #expect(list.touch("a") == [])
        #expect(list.keys == ["b", "c", "a"])
        #expect(list.touch("d") == ["b"])
        #expect(list.keys == ["c", "a", "d"])
    }

    @Test func touchNeverEvictsTouchedKey() {
        var list = LRUList<Int>(capacity: 2)
        _ = list.touch(1)
        _ = list.touch(2)
        #expect(list.shrink(to: 0) == [1, 2])
        _ = list.touch(1)
        _ = list.touch(2)
        _ = list.touch(3)
        #expect(list.keys == [2, 3])

        var empty = LRUList<Int>(capacity: 0)
        #expect(empty.touch(7) == [])
        #expect(empty.touch(8) == [7])
        #expect(empty.keys == [8])
    }

    @Test func removeAndShrinkReturnLeastRecentFirst() {
        var list = LRUList<Int>(capacity: 6)
        for key in 1...5 { _ = list.touch(key) }
        list.remove(3)
        list.remove(9)
        #expect(list.keys == [1, 2, 4, 5])
        #expect(list.shrink(to: 2) == [1, 2])
        #expect(list.keys == [4, 5])
        for key in 6...9 { _ = list.touch(key) }
        #expect(list.keys == [4, 5, 6, 7, 8, 9])
    }
}
