//  Copyright 2022 Thomas Insam. All rights reserved.

import Foundation

class AsyncDataFetcher: AsyncIteratorProtocol {

    typealias Element = Data

    let chunkSize: Int
    let fileHandle: FileHandle

    init(url: URL, chunkSize: Int) throws {
        self.chunkSize = chunkSize
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        fileHandle.closeFile()
    }

    func next() async -> Data? {
        let data = fileHandle.readData(ofLength: chunkSize)
        return data.isEmpty ? nil : data
    }

}
