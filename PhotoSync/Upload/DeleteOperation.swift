// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

enum DeleteError: Error {
    case otherResponse
    case api(Files.DeleteBatchError)
}

class DeleteOperation {
    struct DeleteTask {
        let pathLower: String
        let rev: String
    }

    static func deleteFiles(database: Database, dropboxClient: DropboxClient, tasks: [DeleteTask]) async throws {
        let entries = tasks.map { task in
            Files.DeleteArg(path: task.pathLower, parentRev: task.rev)
        }
        NSLog("%@", "Deleting \(tasks.count) files")

        let batch = try await dropboxClient.files.deleteBatch(entries: entries).asyncResponse()
        switch batch {
        case .complete:
            return
        case .asyncJobId(let jobId):
            try await wait(dropboxClient: dropboxClient, jobId: jobId)
        case .other:
            throw DeleteError.otherResponse
        }

//        try await database.perform { context in
//            tasks.forEach { task in
//                context.delete(context.object(with: task.file.objectID))
//            }
//            try context.save()
//        }
        NSLog("%@", "Deleted \(tasks.count) files")
    }

    static func wait(dropboxClient: DropboxClient, jobId: String) async throws {
        while true {
            NSLog("%@", "Waiting")
            // Wait a random amount before polling again
            try? await Task.sleep(nanoseconds: 6_000_000 * UInt64.random(in: 1_000..<2_000))
            let batch = try await dropboxClient.files.deleteBatchCheck(asyncJobId: jobId).asyncResponse()
            switch batch {
            case .complete:
                // We're done
                return
            case .inProgress:
                // Loop again
                break
            case .failed(let error):
                throw DeleteError.api(error)
            case .other:
                throw DeleteError.otherResponse
            }
        }
    }
}
