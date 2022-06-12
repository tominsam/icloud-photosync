//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
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
        state = ServiceState()
        let context = persistentContainer.newBackgroundContext()
        state!.total = await context.perform {
            Photo.count(in: context)
        }

        var uploads = [BatchUploader.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        try await iterateAllPhotos(inContext: context) { photo, asset, dropboxFile in
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

        NSLog("%@", "Accumulated \(uploads.count) uploads and \(deletions.count) deletions")
        state!.total = uploads.count + deletions.count
        state!.progress = 0
        await progressUpdate(state!)

        // This fetches the photo and does the upload.
        // TODO - we're going half as fast as we could because we're waiting to download
        // the images, then waiting to upload the images - we should be pre-fetching the
        // photos in advance of the upload
        for chunk in uploads.chunked(into: 10) {
            try await upload(chunk)
            state!.progress += chunk.count
            await progressUpdate(state!)
        }

        for chunk in deletions.chunked(into: 10) {
            // TODO: fix deletions
            //                for deletion in deletions {
            //                    try await DeleteOperation.deleteFile(persistentContainer: persistentContainer, dropboxClient: dropboxClient, task: deletion)
            //                }
            state!.progress += chunk.count
            await progressUpdate(state!)
        }

        NSLog("%@", "Upload complete")

        state!.progress = state!.total
        await progressUpdate(state!)
    }

    func upload(_ tasks: [BatchUploader.UploadTask]) async throws {
        let finishResults = try await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: tasks)
        for result in finishResults {
            if case let .failure(path, message) = result {
                state!.errors.append(ServiceError(path: path, message: message))
            }
        }
        await progressUpdate(state!)
    }

    func iterateAllPhotos(inContext context: NSManagedObjectContext, withBlock block: (Photo, PHAsset?, DropboxFile?) async -> Void) async throws {
        let allPhotos = try await Photo.matching("1=1", in: context)
        for photos in allPhotos.chunked(into: 500) {
            // Bulk fetch related assets (photokit photos and dropbox files) for this block
            let rawAssets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map { $0.photoKitId }, options: nil)
            let assets = (0 ..< rawAssets.count).map { rawAssets.object(at: $0) }.uniqueBy(\.localIdentifier)
            let dropboxFiles = try await DropboxFile.matching("pathLower IN %@", args: [photos.map { $0.path.localizedLowercase }], in: context).uniqueBy(\.pathLower)

            for photo in photos {
                let asset = assets[photo.photoKitId]
                let dropboxFile = dropboxFiles[photo.path.localizedLowercase]
                await block(photo, asset, dropboxFile)
            }
        }
    }
}
