//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox
import UIKit

class UploadManager: Manager {

    func sync(allAssets: [PHAsset]) async throws {
        let context = persistentContainer.newBackgroundContext()

        let (changes, deletions) = try await iterateAllPhotos(inContext: context, allAssets: allAssets)

        let uploads = changes.filter { $0.state == .new }
        let replacements = changes.filter { $0.state == .replacement }
        let unknown = changes.filter { $0.state == .unknown }

        var uploadState = await stateManager.createState(named: "New", total: uploads.count)
        var replacementState = await stateManager.createState(named: "Updated", total: replacements.count)
        var unknownState = await stateManager.createState(named: "Unknown", total: unknown.count)
        var deletionState = await stateManager.createState(named: "Deleted", total: deletions.count)

        // prioritize new files
        await uploads.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            await uploadState.increment(chunk.count)
        }
        await uploadState.setComplete()

        // then upload changed files
        await replacements.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            await replacementState.increment(chunk.count)
        }
        await replacementState.setComplete()

        await unknown.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            await unknownState.increment(chunk.count)
        }
        await unknownState.setComplete()

        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough).
        for chunk in deletions.chunked(into: 400) {
            await self.delete(chunk)
            await uploadState.increment(chunk.count)
        }
        await deletionState.setComplete()

        NSLog("%@", "Upload complete")
    }

    func upload(_ tasks: [BatchUploader.UploadTask]) async {
        let finishResults = await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: tasks, stateManager: stateManager)
        for result in finishResults {
            if case let .failure(path, message, error) = result {
                await recordError(ServiceError(path: path, message: message, error: error))
            }
        }
    }

    func delete(_ tasks: [DeleteOperation.DeleteTask]) async {
        do {
            try await DeleteOperation.deleteFiles(persistentContainer: self.persistentContainer, dropboxClient: self.dropboxClient, tasks: tasks)
        } catch {
            await self.recordError(ServiceError(path: "", message: error.localizedDescription, error: error))
        }
    }

    func iterateAllPhotos(inContext context: NSManagedObjectContext, allAssets: [PHAsset]) async throws -> ([BatchUploader.UploadTask], [DeleteOperation.DeleteTask]) {
        let allPhotos = try await Photo.allPhotosWithUniqueFilenames(in: context)
        let assets = allAssets.uniqueBy(\.localIdentifier)
        var dropboxFiles = try await DropboxFile.matching(nil, in: context).uniqueBy(\.pathLower)

        var uploads = [BatchUploader.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        for photo in allPhotos {
            let asset = assets[photo.photoKitId]
            guard let asset else {
                continue
            }

            // Track the dropbox files we've seen in photokit
            let file = dropboxFiles[photo.path.localizedLowercase]
            dropboxFiles.removeValue(forKey: photo.path.localizedLowercase)

            if file != nil && photo.contentHash == file?.contentHash {
                // file is unchanged, we're fine
                continue
            }

            let state: BatchUploader.UploadState
            if file == nil {
                state = .new
            } else if photo.contentHash == nil {
                state = .unknown
            } else {
                state = .replacement
            }
            uploads.append(BatchUploader.UploadTask(asset: asset, filename: photo.path, existingContentHash: file?.contentHash, state: state))
        }

        // Anything left in the dropbox files list needs to be deleted,
        // but isn't in the local photos database
        for (_, file) in dropboxFiles {
            deletions.append(DeleteOperation.DeleteTask(file: file))
        }
        // delete more recent files first
        deletions.sort { (lhs, rhs) in lhs.file.pathLower > rhs.file.pathLower }

        try await context.performSave()
        return (uploads, deletions)
    }
}
