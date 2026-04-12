// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox
import UIKit

/// Manages uploading files - splits files into groups depending on what needs to be done, then
/// performs the upload until we're in a good state.
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
        // We don't have content hashes for these images, we'll need to fetch them from photokit.
        let unknownState = progressManager.createTask(named: "Unknown")
        // removed locally, delete from dropbox. We do that _last_, only remove files once
        // we've uploaded everything to minimize potential for loss
        let deletionState = progressManager.createTask(named: "Deleted")

        // this can take a few seconds for large libraries, but it's
        // not worth trying to share with PhotoKitManager
        let allAssets = await PHAsset.allAssets

        // Group every photo into categories based on if we need to upload it as a new
        // file, or a changed file, or delete it
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

        // prioritize new files - we have the file locally but there's nothing
        // in dropbox with that path. These are therefore new photos and are
        // the most important to back up
        await uploads.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            uploadState.progress += chunk.count
        }
        uploadState.setComplete()

        // then upload changed files - they exist in dropbox, but the content hash
        // is changed. These are edits - probably not that important but also
        // there are naver very many of these.
        await replacements.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            replacementState.progress += chunk.count
        }
        replacementState.setComplete()

        // "unknown" files are files where we don't have content hashes locally. This
        // generally also means edits most of the time, or something happened to
        // the photos database, or we had to re-create the database. This is generally
        // either empty, or huge (because something bad happened). Most of the time
        // it's cheap to process, though - the files probably exist remotely, so we don't
        // need to do uploading here, we just need to fetch the original from photokit
        // and get the hash.
        await unknown.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            unknownState.progress += chunk.count
        }
        unknownState.setComplete()
        
        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough). Do this last, so that we're not deleting
        // things until all the proper backing up is done.
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
        // Everything we _want_ to upload in order
        let allPhotos = try Photo.allPhotosWithUniqueFilenames(in: context)
        // allPhotos is thin objects - build a lookup table for the real assets
        let assets = allAssets.uniqueBy(\.localIdentifier)
        // All the files we know about remotely, accessible by path.
        var dropboxFiles = try DropboxFile.matching(nil, in: context).uniqueBy(\.pathLower)

        var uploads = [UploadOperation.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        for photo in allPhotos {
            guard let asset = assets[photo.photoKitId] else {
                continue
            }

            // Track the dropbox files we've seen in photokit - anything left over
            // after we remove the uploads must need to be deleted.
            let file = dropboxFiles[photo.path.localizedLowercase]
            dropboxFiles.removeValue(forKey: photo.path.localizedLowercase)

            if file != nil && photo.contentHash == file?.contentHash {
                // The destination exists and has the right content hash.
                // We don't need to do anything,
                continue
            }

            let state: UploadOperation.UploadState
            if file == nil {
                // There is no remote file with this path - we need to upload it.
                // (future work - in theory I guess if there is some file somewhere
                // else with the right hash we could move it or copy it?)
                state = .new
            } else if photo.contentHash == nil {
                // There's a file with the right path, but the local photo has no content
                // hash. We need to generate the hash to know what to do.
                state = .unknown
            } else {
                // There's a remote file with one hash, but the local file has a different
                // hash. Must be a local edit (or something caused the target filename to change)
                state = .replacement
            }
            uploads.append(
                UploadOperation.UploadTask(
                    asset: asset,
                    filename: photo.path,
                    existingContentHash: file?.contentHash,
                    state: state
                )
            )
        }

        // Anything left in the dropbox files list needs to be deleted,
        // because it isn't in the local photos database
        for (_, file) in dropboxFiles {
            deletions.append(DeleteOperation.DeleteTask(file: file))
        }
        // delete more recent files first
        deletions.sort { (lhs, rhs) in lhs.file.pathLower > rhs.file.pathLower }

        try context.save()
        return (uploads, deletions)
    }
}
