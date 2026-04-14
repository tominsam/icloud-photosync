// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import Testing
@testable import PhotoSync

struct ContentHashTests {

    @Test func emptyData() {
        // Empty input: no blocks hashed → SHA256 of empty Data
        #expect(Data().dropboxContentHash() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func shortData() {
        // Less than one block: SHA256(SHA256(data))
        let data = Data("hello".utf8)
        #expect(data.dropboxContentHash() == "9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50")
    }

    @Test func multiBlock() {
        // 4MB + 1 byte forces two blocks
        let data = Data(repeating: UInt8(ascii: "A"), count: 4 * 1024 * 1024 + 1)
        #expect(data.dropboxContentHash() == "8f553da8d00d0bf509d8470e242888be33019c20c0544811f5b2b89e98360b92")
    }

    @Test func deterministicOnSameInput() {
        let data = Data("deterministic".utf8)
        #expect(data.dropboxContentHash() == data.dropboxContentHash())
    }

    @Test func differentInputsDifferentHashes() {
        #expect(Data("abc".utf8).dropboxContentHash() != Data("abd".utf8).dropboxContentHash())
    }
}
