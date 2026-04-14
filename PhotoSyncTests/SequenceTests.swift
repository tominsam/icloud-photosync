// Copyright 2026 Thomas Insam. All rights reserved.

import Testing
@testable import PhotoSync

struct SequenceTests {

    @Test func chunkedSplitsEvenly() {
        #expect([1, 2, 3, 4].chunked(into: 2) == [[1, 2], [3, 4]])
    }

    @Test func chunkedHandlesRemainder() {
        #expect([1, 2, 3, 4, 5].chunked(into: 2) == [[1, 2], [3, 4], [5]])
    }

    @Test func chunkedSingleChunk() {
        #expect([1, 2, 3].chunked(into: 10) == [[1, 2, 3]])
    }

    @Test func chunkedEmpty() {
        let result: [[Int]] = [].chunked(into: 3)
        #expect(result.isEmpty)
    }

    @Test func uniqueByKeepsFirst() {
        let pairs = [(1, "a"), (2, "b"), (1, "c")]
        let result = pairs.uniqueBy(\.0)
        #expect(result[1]?.1 == "a")
        #expect(result[2]?.1 == "b")
        #expect(result.count == 2)
    }

    @Test func asyncMapPreservesOrder() async {
        let result = await [1, 2, 3].asyncMap { $0 * 2 }
        #expect(result == [2, 4, 6])
    }
}
