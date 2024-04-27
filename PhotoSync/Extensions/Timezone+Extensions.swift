//  Copyright 2022 Thomas Insam. All rights reserved.

import Foundation

public extension TimeZone {
    init?(fromOffset offset: String) {
        assert(offset.count == 6)
        let parts = offset.split(separator: ":", maxSplits: 1).compactMap { Int($0) }
        assert(parts.count == 2)
        let seconds = parts[0] * 3600 + parts[1] * 60
        self.init(secondsFromGMT: Int(seconds))
    }
}
