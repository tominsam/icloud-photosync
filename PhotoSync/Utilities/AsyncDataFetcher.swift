//  Copyright 2022 Thomas Insam. All rights reserved.

import Foundation

/// Async iterator that returns the binary contents of a file in chunks of a provided
/// size, keep looping on it until it's finished and you'll have the whole file.
class AsyncDataFetcher: AsyncIteratorProtocol {
    typealias Element = Data

    let chunkSize: Int
    let fileHandle: FileHandle

    init(url: URL, chunkSize: Int) throws {
        self.chunkSize = chunkSize
        fileHandle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        fileHandle.closeFile()
    }

    func next() async -> Data? {
        let data = fileHandle.readData(ofLength: chunkSize)
        return data.isEmpty ? nil : data
    }
}
