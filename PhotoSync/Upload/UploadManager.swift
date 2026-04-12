// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox
import UIKit

@MainActor
class UploadManager {
    let database: Database
    let dropboxClient: DropboxClient

    let progressManager: ProgressManager
    private let errorUpdate: (ServiceError) -> Void

    func recordError(_ message: String, path: String = "/", error: Error? = nil) {
        errorUpdate(ServiceError(path: path, message: message, error: error))
    }

    init(database: Database, dropboxClient: DropboxClient, progressManager: ProgressManager, errorUpdate: @escaping (ServiceError) -> Void) {
        self.database = database
        self.dropboxClient = dropboxClient
        self.progressManager = progressManager
        self.errorUpdate = errorUpdate
    }

    func sync() async {
        do {
            try await internalSync()
        } catch {
            recordError(error.localizedDescription)
        }
    }
    
    func internalSync() async throws {
        // Create all the state objects first so we update the UI.
        
        // new images that need to be uploaded
        let uploadState = progressManager.createTask(named: "New")
        // locally changed images need to be replaces
        let replacementState = progressManager.createTask(named: "Updated")
        // We don't have content hashes for these images, we'll need to fetch them from photokit
        let unknownState = progressManager.createTask(named: "Unknown")
        // removed locally, delete from dropbox. We do that _last_, only remove files once
        // we've uploaded everything to minimize potential for loss
        let deletionState = progressManager.createTask(named: "Deleted")

        // this can take a few seconds for large libraries, but it's
        // not worth trying to share with PhotoKitManager
        let allAssets = await PHAsset.allAssets

        let (changes, deletions) = try await database.perform { [self] context in
            try iterateAllPhotos(inContext: context, allAssets: allAssets)
        }

        if deletions.count > 1000 {
            // emergency sanity check to prevent the wrong login from destroying the server
            fatalError("Too many deletions")
        }

        let uploads = changes.filter { $0.state == .new }
        let replacements = changes.filter { $0.state == .replacement }
        let unknown = changes.filter { $0.state == .unknown }

        uploadState.total = uploads.count
        replacementState.total = replacements.count
        unknownState.total = unknown.count
        deletionState.total = deletions.count

        // prioritize new files
        await uploads.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            uploadState.progress += chunk.count
        }
        uploadState.setComplete()

        // then upload changed files
        await replacements.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            replacementState.progress += chunk.count
        }
        replacementState.setComplete()

        await unknown.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            unknownState.progress += chunk.count
        }
        unknownState.setComplete()
        
        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough).
        for chunk in deletions.chunked(into: 400) {
            await self.delete(chunk)
            uploadState.progress += chunk.count
        }
        deletionState.setComplete()

        NSLog("%@", "Upload complete")
    }

    func upload(_ tasks: [UploadOperation.UploadTask]) async {
        let finishResults = await UploadOperation.batchUpload(
            database: database,
            dropboxClient: dropboxClient,
            tasks: tasks,
            progressManager: progressManager
        )
        for result in finishResults {
            if case let .failure(path, message, error) = result {
                recordError(message, path: path, error: error)
            }
        }
    }

    func delete(_ tasks: [DeleteOperation.DeleteTask]) async {
        do {
            try await DeleteOperation.deleteFiles(database: database, dropboxClient: self.dropboxClient, tasks: tasks)
        } catch {
            recordError(error.localizedDescription)
        }
    }

    nonisolated func iterateAllPhotos(
        inContext context: NSManagedObjectContext,
        allAssets: [PHAsset]
    ) throws -> ([UploadOperation.UploadTask], [DeleteOperation.DeleteTask]) {
        let allPhotos = try Photo.allPhotosWithUniqueFilenames(in: context)
        let assets = allAssets.uniqueBy(\.localIdentifier)
        var dropboxFiles = try DropboxFile.matching(nil, in: context).uniqueBy(\.pathLower)

        var uploads = [UploadOperation.UploadTask]()
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

            let state: UploadOperation.UploadState
            if file == nil {
                state = .new
            } else if photo.contentHash == nil {
                state = .unknown
            } else {
                state = .replacement
            }
            uploads.append(UploadOperation.UploadTask(asset: asset, filename: photo.path, existingContentHash: file?.contentHash, state: state))
        }

        // Anything left in the dropbox files list needs to be deleted,
        // but isn't in the local photos database
        for (_, file) in dropboxFiles {
            deletions.append(DeleteOperation.DeleteTask(file: file))
        }
        // delete more recent files first
        deletions.sort { (lhs, rhs) in lhs.file.pathLower > rhs.file.pathLower }

        try context.save()
        return (uploads, deletions)
    }
}
