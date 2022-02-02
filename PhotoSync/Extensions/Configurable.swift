//
//  Configurable.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation

internal protocol Configurable {}

extension Configurable {
    func configured(with: (inout Self) throws -> Void) rethrows -> Self {
        var mutable = self
        try with(&mutable)
        return mutable
    }
}

extension NSObject: Configurable {}
