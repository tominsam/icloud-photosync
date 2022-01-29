//
//  BatchUploader.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import SwiftyDropbox
import Photos


// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
class BatchUploader: LoggingOperation {

    struct UploadTask {
        let asset: PHAsset
        let filename: String
        let existingContentHash: String?
    }

    // Internal operation queue to manage parallelization.
    lazy var operationQueue = OperationQueue().configured {
        $0.maxConcurrentOperationCount = 3
    }

    let tasks: [UploadTask]
    let dropboxClient = AppDelegate.shared.dropboxManager.dropboxClient!

    init(tasks: [UploadTask]) {
        self.tasks = tasks
    }

    func run() {
        let operations = tasks.map { UploadStartOperation(task: $0) }

        // Queue all the assets for upload
        operationQueue.addOperations(operations, waitUntilFinished: true)

        // Once all the uploads are done, collect the results and make a single call to dropbox that closes the transaction.
        // Map the operation results into the data structure that uploadSessionFinishBatch expects
        let finishEntries = operations.compactMap { $0.finishEntry }
        guard !finishEntries.isEmpty else {
            // Everything in the batch was already on dropbox
            //NSLog("Nothing to upload")
            return
        }

        // We want to block main until the operation is complete. Sure, there are cleverer ways of doing
        // this but why bother?
        let sema = DispatchSemaphore(value: 0)

        NSLog("Finishing \(finishEntries.count) uploads")
        dropboxClient.files.uploadSessionFinishBatchV2(entries: finishEntries).response { [unowned self] result, error in
            guard let result = result else {
                self.logError(error: error!.description)
                return
            }
            var success = [Files.FileMetadata]()
            var failure = [Files.UploadSessionFinishError]()
            for entry in result.entries {
                switch entry {
                case .success(let fileMetadata):
                    success.append(fileMetadata)
                case .failure(let error):
                    failure.append(error)
                }
            }
            self.jobComplete(success: success, failure: failure, sema: sema)
        }

        _ = sema.wait(timeout: .distantFuture)
    }

    func jobComplete(success: [Files.FileMetadata], failure: [Files.UploadSessionFinishError], sema: DispatchSemaphore) {
        // Now we've uploaded all the files, we can connect them to the original assets in core data.
        NSLog("Complete")
        // Really need better error handling
        AppDelegate.shared.persistentContainer.performBackgroundTask { context in
            for file in success {
                DropboxFile.insertOrUpdate([file], syncRun: "", into: context)
            }
            for _ in failure {
                fatalError()
            }
            try! context.save()
            sema.signal()
        }
    }

}


// Fetches a PHAsset from iCloud and pushes it to Dropbox as part of a batch start
class UploadStartOperation: Operation, LoggingOperation {
    // What to push
    let task: BatchUploader.UploadTask

    // The thing that was pushed
    var result: Files.UploadSessionStartResult?
    var bytes: UInt64 = 0

    init(task: BatchUploader.UploadTask) {
        self.task = task
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }

        switch task.asset.mediaType {
        case .image:
            break
        default:
            //NSLog("Skipping media type \(task.asset.mediaType.rawValue)")
            return
        }

        // Get original asset data from photokit
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current // save out edited versions (or original if no edits)
        options.isSynchronous = true // block operation
        manager.requestImageDataAndOrientation(for: task.asset, options: options) { [unowned self] data, uti, orientation, info in
            guard !self.isCancelled else { return }

            guard let data = data, let hash = data.dropboxContentHash() else {
                self.logError(error: "Failed to fetch image \(self.task.filename)")
                return
            }

            // Store the content hash on the database object before we start the upload
            let context = AppDelegate.shared.persistentContainer.newBackgroundContext()
            context.performAndWait {
                if let photo = Photo.forAsset(self.task.asset, in: context) {
                    photo.contentHash = hash
                    try! context.save()
                }
            }

            // Skip the upload if possible
            if self.task.existingContentHash != hash {
                // Blocking call that uploads to dropbox and counts the bytes
                NSLog("Uploading \(self.task.filename) with \(hash) replacing \(self.task.existingContentHash ?? "nil")")
                self.upload(data: data)
            }
        }
    }

    func upload(data: Data) {
        let sema = DispatchSemaphore(value: 0)
        AppDelegate.shared.dropboxManager.dropboxClient!.files.uploadSessionStart(close: true, input: data).response { result, error in
            self.result = result
            self.bytes = UInt64(data.count)
            sema.signal()
        }
        _ = sema.wait(timeout: .distantFuture)
    }

    /// returns the dropbox batch upload finish argument object, which we use to close out the upload
    var finishEntry: Files.UploadSessionFinishArg? {
        guard let result = result else {
            return nil
        }
        let cursor = Files.UploadSessionCursor(sessionId: result.sessionId, offset: bytes)
        let commitInfo = Files.CommitInfo(path: task.filename, mode: .overwrite, autorename: false, clientModified: task.asset.creationDate ?? task.asset.modificationDate)
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

}


