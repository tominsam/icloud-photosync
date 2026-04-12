// Copyright 2020 Thomas Insam. All rights reserved.

import Foundation

public extension Sequence {
    /// Convert a sequence into a dictionary where the key is some keypath on the sequence
    /// and the value is the first element in the sequence with that value. Duplicate entries
    /// in the sequence with the same value from the keypath are discarded.
    func uniqueBy<Key>(_ path: KeyPath<Element, Key>) -> [Key: Element] {
        return Dictionary(map { ($0[keyPath: path], $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Array {
    /// Convert an array into an array of arrays of elements, with up to "size" elements in each
    /// sub-array. Every element in the original array is returned, in the same order.
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Sequence where Element: Sendable {
    /// map equivalent for a sequence, but the map block is async, and we will run up to `maxJobs`
    /// blocks simultaneously.
    /// Notes - return ordering is indeterminate, should fix that
    @discardableResult
    func parallelMap<T>(maxJobs: Int, block: @escaping (Element) async throws -> T) async rethrows -> [T] {
        var results = [T]()
        try await withThrowingTaskGroup(of: T.self) { group in
            for (offset, element) in enumerated() {
                if offset >= maxJobs {
                    results.append(try await group.next()!)
                }
                group.addTask {
                    return try await block(element)
                }
            }
            for try await result in group {
                results.append(result)
            }
        }
        return results
    }
}
