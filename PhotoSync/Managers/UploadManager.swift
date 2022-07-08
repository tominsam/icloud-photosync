//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox
import UIKit
import AsyncAlgorithms

class UploadManager: Manager {

    func sync() async throws {
        let context = persistentContainer.newBackgroundContext()
        let count = await context.perform { Photo.count(in: context) }
        await setTotal(count)

        let (changes, deletions) = try await iterateAllPhotos(inContext: context)

        let uploads = changes.filter { $0.isNewFile }
        let replacements = changes.filter { !$0.isNewFile }

        NSLog("%@", "Accumulated \(uploads.count) uploads, \(replacements.count) replacements, and \(deletions.count) deletions")
        await setTotal(uploads.count + replacements.count + deletions.count)

        // prioritize new files
        await uploads.chunked(into: 10).parallelMap(maxJobs: 3) { chunk in
            await self.upload(chunk)
            await self.addProgress(chunk.count)
        }

        // then upload changed files
        await replacements.chunked(into: 10).parallelMap(maxJobs: 3) { chunk in
            await self.upload(chunk)
            await self.addProgress(chunk.count)
        }

        // then delete removed files
        await deletions.chunked(into: 20).parallelMap(maxJobs: 4) { chunk in
            await self.delete(chunk)
            await self.addProgress(chunk.count)
        }

        NSLog("%@", "Upload complete")
        await markComplete()
    }

    func upload(_ tasks: [BatchUploader.UploadTask]) async {
        let finishResults = await BatchUploader.batchUpload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, tasks: tasks)
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

    func iterateAllPhotos(inContext context: NSManagedObjectContext) async throws -> ([BatchUploader.UploadTask], [DeleteOperation.DeleteTask]) {
        let allPhotos = try await Photo.matching(nil, in: context)
        let assets = await PHAsset.allAssets.uniqueBy(\.localIdentifier)
        var dropboxFiles = try await DropboxFile.matching(nil, in: context).uniqueBy(\.pathLower)

        var uploads = [BatchUploader.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        for photo in allPhotos {
            let asset = assets[photo.photoKitId]
            guard let asset else {
                await context.perform { context.delete(photo) }
                continue
            }

            let file = dropboxFiles[photo.path.localizedLowercase]
            dropboxFiles.removeValue(forKey: photo.path.localizedLowercase)

            if file == nil || photo.contentHash != file?.contentHash {
                uploads.append(BatchUploader.UploadTask(asset: asset, filename: photo.path, existingContentHash: file?.contentHash, isNewFile: file == nil))
            }
        }

        // Anything left in the dropbox files list needs to be deleted,
        // but isn't in the local photos database
        for (_, file) in dropboxFiles {
            deletions.append(DeleteOperation.DeleteTask(file: file))
        }
        // delete more recent files first
        deletions.sort { (lhs, rhs) in lhs.file.pathLower > rhs.file.pathLower }

        return (uploads, deletions)
    }
}
