//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

class UploadManager {
    let persistentContainer: NSPersistentContainer
    let dropboxClient: DropboxClient
    let progressUpdate: @MainActor(ServiceState) -> Void

    var state: ServiceState?

    init(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, progressUpdate: @MainActor @escaping (ServiceState) -> Void) {
        self.persistentContainer = persistentContainer
        self.dropboxClient = dropboxClient
        self.progressUpdate = progressUpdate
    }

    func sync() async throws {
        var state = ServiceState()
        self.state = state
        let context = persistentContainer.newBackgroundContext()
        state.total = await context.perform {
            Photo.count(in: context)
        }

        let runIdentifier = UUID().uuidString
        var uploads = [BatchUploader.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        while true {
            // fetch the next block of photos that need uploading
            let photos = await context.perform {
                Photo.matching("uploadRun != %@ OR uploadRun == nil", args: [runIdentifier], limit: 10, in: context)
            }
            if photos.isEmpty {
                break
            }

            // Bulk fetch assets for this block
            let rawAssets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map { $0.photoKitId }, options: nil)
            let assets = (0 ..< rawAssets.count).map { rawAssets.object(at: $0) }.uniqueBy(\.localIdentifier)
            let dropboxFiles = DropboxFile.matching("pathLower IN %@", args: [photos.map { $0.path.localizedLowercase }], in: context).uniqueBy(\.pathLower)

            for photo in photos {
                let asset = assets[photo.photoKitId]
                let dropboxFile = dropboxFiles[photo.path.localizedLowercase]

                switch (asset, dropboxFile) {
                case (.none, .none):
                    // No photokit object, no dropbox object. The local photo object should not exist
                    await context.perform {
                        context.delete(photo)
                    }

                case let (.some(asset), .none):
                    // Object exists in PhotoKit but not in dropbox. Upload it
                    uploads.append(.init(asset: asset, filename: photo.path, existingContentHash: nil))

                case let (.none, .some(file)):
                    // Object exists in dropbox but not PhotoKit. Delete from Dropbox
                    deletions.append(.init(photoKitId: photo.photoKitId, file: file))

                case let (.some(asset), .some(file)):
                    // Object exists in both. Does it need syncing
                    if photo.contentHash != file.contentHash {
                        uploads.append(.init(asset: asset, filename: photo.path, existingContentHash: file.contentHash))
                    }
                }
            }

            // this excludes the photos from the next loop - it's much safer than
            // paginating them, as long as there's only one instance of UploadManager
            // running at once
            await context.perform {
                for photo in photos {
                    photo.uploadRun = runIdentifier
                }
            }

            state.progress += photos.count

            // The uploader also manipulates the photo object, so avoid conflicts by letting go here.
            try await context.perform {
                try context.save()
                context.reset()
            }

            NSLog("%@", "Accumulated \(uploads.count) uploads and \(deletions.count) deletions")

            if uploads.count >= 10 {
                try await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: uploads)
                uploads = []
            }

            if !deletions.isEmpty {
                for deletion in deletions {
                    try await DeleteOperation.deleteFile(persistentContainer: persistentContainer, dropboxClient: dropboxClient, task: deletion)
                }
                deletions = []
            }

            await progressUpdate(state)
        }

        try await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: uploads)
        for deletion in deletions {
            try await DeleteOperation.deleteFile(persistentContainer: persistentContainer, dropboxClient: dropboxClient, task: deletion)
        }

        NSLog("%@", "Upload complete")

        state.progress = state.total
        await progressUpdate(state)
    }
}
