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
        let count = await context.perform { Photo.count(in: context) }

        let (changes, deletions) = try await iterateAllPhotos(inContext: context, allAssets: allAssets)

        let uploads = changes.filter { $0.state == .new }
        let replacements = changes.filter { $0.state == .replacement }
        let unknown = changes.filter { $0.state == .unknown }

        await setProgress(0, total: uploads.count, named: "Uploads")
        await setProgress(0, total: replacements.count, named: "Replacements")
        await setProgress(0, total: unknown.count, named: "Unknown")
        await setProgress(0, total: deletions.count, named: "Deletions")

        NSLog("%@", "Accumulated \(uploads.count) uploads, \(replacements.count) replacements, \(unknown.count) unknown, and \(deletions.count) deletions")

        // prioritize new files
        var uploadsComplete = 0
        await uploads.chunked(into: 10).parallelMap(maxJobs: 3) { chunk in
            await self.upload(chunk)
            uploadsComplete += chunk.count
            await self.setProgress(uploadsComplete, total: uploads.count, named: "Uploads")
        }
        await markComplete(uploads.count, named: "Uploads")

        // then upload changed files
        var replacementsComplete = 0
        await replacements.chunked(into: 10).parallelMap(maxJobs: 3) { chunk in
            await self.upload(chunk)
            replacementsComplete += chunk.count
            await self.setProgress(replacementsComplete, total: replacements.count, named: "Replacements")
        }
        await markComplete(replacements.count, named: "Replacements")

        var unknownComplete = 0
        await unknown.chunked(into: 10).parallelMap(maxJobs: 3) { chunk in
            await self.upload(chunk)
            unknownComplete += chunk.count
            await self.setProgress(unknownComplete, total: unknown.count, named: "Unknown")
        }
        await markComplete(unknown.count, named: "Unknown")

        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough).
        // TODO this should be a separate progress bar
        var deletionsComplete = 0
        for chunk in deletions.chunked(into: 400) {
            await self.delete(chunk)
            deletionsComplete += chunk.count
            await self.setProgress(deletionsComplete, total: deletions.count, named: "Deletions")
        }
        await markComplete(deletions.count, named: "Deletions")

        NSLog("%@", "Upload complete")
    }

    func upload(_ tasks: [BatchUploader.UploadTask]) async {
        let finishResults = await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: tasks, progressUpdate: progressUpdate)
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
            uploads.append(BatchUploader.UploadTask(asset: asset, filename: photo.path, existingContentHash: file?.contentHash, cloudIdentifier: photo.cloudIdentifier, state: state))
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
