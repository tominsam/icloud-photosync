// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox
import UIKit

/// Collects upload-ready items and flushes a batch once the accumulated byte size crosses a threshold.
private actor UploadAccumulator {
    private var pending: [(UploadOperation.UploadTask, AssetData)] = []
    private var pendingBytes: Int = 0
    private let threshold: Int

    init(threshold: Int = 20 * 1_024 * 1_024) {
        self.threshold = threshold
    }

    /// Adds items one at a time, flushing a batch each time the threshold is crossed.
    /// Returns all batches that became ready (may be more than one if a chunk is large).
    func add(_ items: [(UploadOperation.UploadTask, AssetData)]) -> [[(UploadOperation.UploadTask, AssetData)]] {
        var batches: [[(UploadOperation.UploadTask, AssetData)]] = []
        for item in items {
            pending.append(item)
            pendingBytes += item.1.byteSize
            if pendingBytes >= threshold {
                batches.append(pending)
                pending = []
                pendingBytes = 0
            }
        }
        return batches
    }

    func flush() -> [(UploadOperation.UploadTask, AssetData)] {
        defer { pending = []; pendingBytes = 0 }
        return pending
    }
}

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
    func plan(allAssets: [PHAssetProtocol]) async throws -> SyncPlan {
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

        planningState.progress += 1

        // Group every photo into categories based on if we need to upload it as a new
        // file, or a changed file, or delete it
        let (changes, deletions) = try await database.perform { context in
            // Everything we _want_ to upload in order (this is expensive)
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

        planningState.remove()

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

    /// Fetches and saves content hashes for unknown items only, without uploading anything.
    func fetchUnknownOnly(plan: SyncPlan) async {
        plan.uploadState.remove()
        plan.replacementState.remove()
        plan.deletionState.remove()

        await plan.unknown.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            let ready = await UploadOperation.fetchBatch(
                database: self.database,
                tasks: chunk,
                progressManager: self.progressManager
            )
            // We're not uploading here — clean up any temp files for items whose hash
            // didn't match Dropbox (fetchBatch already cleaned up the ones that did match).
            for (_, data) in ready { data.cleanup() }
            plan.unknownState.progress += chunk.count
        }
        plan.unknownState.setComplete()
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
        await runPipeline(tasks: plan.uploads, state: plan.uploadState)

        // then upload changed files - they exist in dropbox, but the content hash
        // is changed. These are edits - probably not that important but also
        // there are never very many of these.
        await runPipeline(tasks: plan.replacements, state: plan.replacementState)

        // "unknown" files are files where we don't have content hashes locally. This
        // generally also means edits most of the time, or something happened to
        // the photos database, or we had to re-create the database. This is generally
        // either empty, or huge (because something bad happened). Most of the time
        // it's cheap to process, though - the files probably exist remotely, so we don't
        // need to do uploading here, we just need to fetch the original from photokit
        // and get the hash.
        await runPipeline(tasks: plan.unknown, state: plan.unknownState)

        // then delete removed files (don't need parallel here, the server
        // batch call is fast enough). Do this last, so that we're not deleting
        // things until all the proper backing up is done.
        for chunk in plan.deletions.chunked(into: 100) {
            await self.delete(chunk)
            plan.deletionState.progress += chunk.count
        }
        plan.deletionState.setComplete()

        NSLog("%@", "Upload complete")
    }

    /// Fetches tasks in parallel chunks of 10, accumulates upload-ready items by byte size,
    /// and fires an upload batch once 20 MB is queued. A single TaskProgress is created lazily
    /// when the first upload-worthy item arrives, grows thumbnails during accumulation, then
    /// transitions to showing upload progress when the batch is handed off.
    private func runPipeline(tasks: [UploadOperation.UploadTask], state: TaskProgress) async {
        let accumulator = UploadAccumulator()

        await tasks.chunked(into: 10).parallelMap(maxJobs: 2) { chunk in
            let ready = await UploadOperation.fetchBatch(
                database: self.database,
                tasks: chunk,
                progressManager: self.progressManager
            )
            state.progress += chunk.count
            for batch in await accumulator.add(ready) {
                await self.uploadAndRecord(batch)
            }
        }

        let remaining = await accumulator.flush()
        if !remaining.isEmpty {
            await uploadAndRecord(remaining)
        }
        state.setComplete()
    }

    private func uploadAndRecord(_ items: [(UploadOperation.UploadTask, AssetData)]) async {
        let results = await UploadOperation.uploadBatch(
            dropboxClient: dropboxClient,
            items: items,
            progressManager: progressManager
        )
        for result in results {
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
            } else if photo.contentHash != file?.contentHash {
                // There's a remote file with one hash, but the local file has a different
                // hash. Must be a local edit (or something caused the target filename to change)
                state = .replacement
            } else {
                // The destination exists and has the right content hash.
                // We don't need to do anything,
                continue
            }

            uploads.append(
                UploadOperation.UploadTask(
                    asset: asset,
                    filename: photo.path,
                    existingContentHash: file?.contentHash,
                    assetContentHash: photo.contentHash,
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
