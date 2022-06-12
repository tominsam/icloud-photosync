//
//  DeleteOperation.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

class DeleteOperation {
    struct DeleteTask {
        let photoKitId: String
        let file: DropboxFile
    }

    static func deleteFile(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, task: DeleteTask) async throws {
        _ = try await dropboxClient.files.deleteV2(path: task.file.pathLower, parentRev: task.file.rev).asyncResponse()
        NSLog("Deleted \(task.file.pathLower)")

        // It's neither in the local store or the remote. We can remove it from the database
        let context = persistentContainer.newBackgroundContext()
        if let photo = try await Photo.matching("photoKitId = %@", args: [task.photoKitId], in: context).first {
            try await context.perform {
                context.delete(photo)
                try context.save()
            }
        }
    }
}
