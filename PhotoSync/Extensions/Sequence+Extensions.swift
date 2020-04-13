//
//  Sequence+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation

extension Sequence {

    public func groupBy<Key: Hashable>(_ group: (Element) -> Key) -> [Key: [Element]] {
        return Dictionary(grouping: self, by: group)
    }

    public func groupBy<Key>(_ path: KeyPath<Element, Key>) -> [Key: [Element]] {
        return Dictionary(grouping: self, by: { $0[keyPath:path] })
    }

    public func uniqueBy<Key>(_ group: (Element) -> Key) -> [Key: Element] {
        return Dictionary(self.map { (group($0), $0) }, uniquingKeysWith: { (first, _) in first })
    }

    public func uniqueBy<Key>(_ path: KeyPath<Element, Key>) -> [Key: Element] {
        return Dictionary(self.map { ($0[keyPath:path], $0) }, uniquingKeysWith: { (first, _) in first })
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
