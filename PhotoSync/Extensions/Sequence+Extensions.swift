//
//  Sequence+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation

public extension Sequence {
    func groupBy<Key: Hashable>(_ group: (Element) -> Key) -> [Key: [Element]] {
        return Dictionary(grouping: self, by: group)
    }

    func groupBy<Key>(_ path: KeyPath<Element, Key>) -> [Key: [Element]] {
        return Dictionary(grouping: self, by: { $0[keyPath: path] })
    }

    func uniqueBy<Key>(_ group: (Element) -> Key) -> [Key: Element] {
        return Dictionary(map { (group($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func uniqueBy<Key>(_ path: KeyPath<Element, Key>) -> [Key: Element] {
        return Dictionary(map { ($0[keyPath: path], $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Collection where Element: Sendable {
    // Notes - return ordering is indeterminate, should fix that
    @discardableResult
    func parallelMap<T>(maxJobs: Int = 5, block: @escaping (Element) async throws -> T) async rethrows -> [T] {
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
