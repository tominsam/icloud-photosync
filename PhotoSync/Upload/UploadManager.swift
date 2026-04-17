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

    struct SyncPlan {
        let uploads: [UploadOperation.UploadTask]
        let replacements: [UploadOperation.UploadTask]
        let unknown: [UploadOperation.UploadTask]
        let deletions: [DeleteOperation.DeleteTask]
        let uploadState: TaskProgress
        let replacementState: TaskProgress
        let unknownState: TaskProgress
        let deletionState: TaskProgress

        var isEmpty: Bool {
            uploads.isEmpty && replacements.isEmpty && unknown.isEmpty && deletions.isEmpty
        }

        func removeStates() {
            uploadState.remove()
            replacementState.remove()
            unknownState.remove()
            deletionState.remove()
        }
    }

    /// Categorizes all work to be done without performing any uploads or deletions.
    /// The returned plan's TaskProgress objects are already registered with the ProgressManager
    /// so counts are visible in the UI immediately.
    func plan() async throws -> SyncPlan {
        let planningState = progressManager.createTask(named: "Planning", total: 5, category: .upload)
        try await Task.sleep(for: .milliseconds(100))

        // new images that need to be uploaded
        let uploadState = progressManager.createTask(named: "New", category: .upload)
        try await Task.sleep(for: .milliseconds(100))

        // locally changed images need to be replaced
        let replacementState = progressManager.createTask(named: "Updated", category: .upload)
        try await Task.sleep(for: .milliseconds(100))

        // We don't have content hashes for these images, we'll need to fetch them from photokit.
        let unknownState = progressManager.createTask(named: "Unknown", category: .upload)
        try await Task.sleep(for: .milliseconds(100))

        // removed locally, delete from dropbox. We do that _last_, only remove files once
        // we've uploaded everything to minimize potential for loss
        let deletionState = progressManager.createTask(named: "Deleted", category: .upload)

        // this can take a few seconds for large libraries, but it's
        // not worth trying to share with PhotoKitManager
        let allAssets = await PHAsset.allAssets
        planningState.progress += 1

        // Group every photo into categories based on if we need to upload it as a new
        // file, or a changed file, or delete it
        let (changes, deletions) = try await database.perform { context in
            // Everything we _want_ to upload in order
            let allPhotos = try Photo.allPhotosWithUniqueFilenames(in: context)
            planningState.progress += 1
            // All the files we know about remotely, accessible by path.
            let allFiles = try DropboxFile.matching(nil, in: context)
            planningState.progress += 1

            return try Self.iterate(photos: allPhotos, files: allFiles, assets: allAssets)
        }
        planningState.progress += 1

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

        planningState.setComplete()
        
        return SyncPlan(
            uploads: uploads,
            replacements: replacements,
            unknown: unknown,
            deletions: deletions,
            uploadState: uploadState,
            replacementState: replacementState,
            unknownState: unknownState,
            deletionState: deletionState
        )
    }

    /// Performs the uploads and deletions described in the plan.
    func execute(plan: SyncPlan) async {
        do {
            try await internalExecute(plan: plan)
        } catch {
            recordError(error.localizedDescription)
        }
    }

    private func internalExecute(plan: SyncPlan) async throws {
        // prioritize new files - we have the file locally but there's nothing
        // in dropbox with that path. These are therefore new photos and are
        // the most important to back up
        await plan.uploads.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            plan.uploadState.progress += chunk.count
        }
        plan.uploadState.setComplete()

        // then upload changed files - they exist in dropbox, but the content hash
        // is changed. These are edits - probably not that important but also
        // there are never very many of these.
        await plan.replacements.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            plan.replacementState.progress += chunk.count
        }
        plan.replacementState.setComplete()

        // "unknown" files are files where we don't have content hashes locally. This
        // generally also means edits most of the time, or something happened to
        // the photos database, or we had to re-create the database. This is generally
        // either empty, or huge (because something bad happened). Most of the time
        // it's cheap to process, though - the files probably exist remotely, so we don't
        // need to do uploading here, we just need to fetch the original from photokit
        // and get the hash.
        await plan.unknown.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            await self.upload(chunk)
            plan.unknownState.progress += chunk.count
        }
        plan.unknownState.setComplete()

        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough). Do this last, so that we're not deleting
        // things until all the proper backing up is done.
        for chunk in plan.deletions.chunked(into: 400) {
            await self.delete(chunk)
            plan.deletionState.progress += chunk.count
        }
        plan.deletionState.setComplete()

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

    /// Build a list of things to do based on the ground state of the device
    /// - Parameters:
    ///   - photos: A list of the photos we _want_ to exist, along with the path we want them to have
    ///   - files: All the files that exist in the remote server
    ///   - assets: A list of PHAssets on the local device
    /// - Returns: Two sets of tasks - the array of UploadTask objects are the photos we might need to upload,
    /// (classified into "must be uploaded", becaue they're newly created or changed files, and "might need to be uploaded",
    /// because we don't have a contentHash for those files) and the DeleteTask array is files the need to be removed from the server.
    nonisolated static func iterate(
        photos: [Photo.PhotoMapping],
        files: [DropboxFileProtocol],
        assets: [PHAssetProtocol],
    ) throws -> ([UploadOperation.UploadTask], [DeleteOperation.DeleteTask]) {
        // the objects in Photos are thin - build a lookup table for the real assets
        let assetsLookup = assets.uniqueBy(\.localIdentifier)
        var filesLookup: [String: DropboxFileProtocol] = files.uniqueBy(\.pathLower)

        var uploads = [UploadOperation.UploadTask]()
        var deletions = [DeleteOperation.DeleteTask]()

        for photo in photos {
            guard let asset = assetsLookup[photo.photoKitId] else {
                continue
            }

            // Track the dropbox files we've seen in photokit - anything left over
            // after we remove the uploads must need to be deleted.
            let file = filesLookup[photo.path.localizedLowercase]
            filesLookup.removeValue(forKey: photo.path.localizedLowercase)

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
        for (_, file) in filesLookup {
            deletions.append(DeleteOperation.DeleteTask(pathLower: file.pathLower, rev: file.rev))
        }
        // delete more recent files first (month is in the path)
        deletions.sort { (lhs, rhs) in lhs.pathLower > rhs.pathLower }

        return (uploads, deletions)
    }
}
