//
//  DeleteOperation.swift
//  PhotoSync
//
//  Created by Thomas Insam on 5/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation
import SwiftyDropbox
import Photos

class DeleteOperation: Operation, LoggingOperation {
    struct DeleteTask {
        let photoKitId: String
        let file: DropboxFile
    }

    let photoKitId: String
    let path: String
    let rev: String

    init(photoKitId: String, path: String, rev: String) {
        self.photoKitId = photoKitId
        self.path = path
        self.rev = rev
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        let sema = DispatchSemaphore(value: 0)

        AppDelegate.shared.dropboxManager.dropboxClient?.files.deleteV2(path: path, parentRev: rev).response { [unowned self] _, error in
            if let error = error {
                self.logError(path: self.path, error: error)
            } else {
                NSLog("Deleted \(self.path)")
                // It's neither in the local store or the remote. We can remove it from the database
                let context = AppDelegate.shared.persistentContainer.viewContext
                if let photo = Photo.matching("photoKitId = %@", args: [self.photoKitId], in: context).first {
                    context.delete(photo)
                    try! photo.managedObjectContext!.save()
                }
            }
            sema.signal()
        }

        _ = sema.wait(timeout: .distantFuture)
        logProgress()
    }
}
