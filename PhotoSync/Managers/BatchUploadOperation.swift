//
//  BatchUploadOperation.swift
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
class BatchUploadOperation: Operation {

    // Internal operation queue to manage parallelization.
    let operationQueue = OperationQueue().configured {
        $0.maxConcurrentOperationCount = 3
    }

    // The assets to upload
    let assets: [PHAsset]

    init(assets: [PHAsset]) {
        self.assets = assets
        super.init()
    }

    override func main() {
        // We want to block main until the operation is complete. Sure, there are cleverer ways of doing
        // this but why bother?
        let sema = DispatchSemaphore(value: 0)

        // Queue all the assets for upload
        let operations = assets.map { UploadStartOperation(asset: $0) }
        operationQueue.addOperations(operations, waitUntilFinished: false)

        // Once all the uploads are done, collect the results and make a single call to dropbox that closes the transaction.
        operationQueue.addBarrierBlock {
            // Map the operation results into the data structure that uploadSessionFinishBatch expects
            let finishEntries: [Files.UploadSessionFinishArg] = operations.map { operation in
                let cursor = Files.UploadSessionCursor(sessionId: operation.result!.sessionId, offset: operation.bytes)
                let commitInfo = Files.CommitInfo(path: operation.asset.dropboxPath, mode: .overwrite, autorename: false, clientModified: operation.asset.creationDate ?? operation.asset.modificationDate)
                return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
            }

            NSLog("Finishing \(finishEntries.count) uploads")
            AppDelegate.shared.dropboxManager.dropboxClient!.files.uploadSessionFinishBatch(entries: finishEntries).response { result, error in
                // Now we need to poll and wait for the upload to complete
                if let result = result {
                    switch result {
                    case .asyncJobId(let jobId):
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                            self.checkJob(jobId: jobId, sema: sema)
                        }
                    case .complete(let complete):
                        self.jobComplete(batchResult: complete, sema: sema)
                    case .other:
                        break
                    }
                } else {
                    self.logError(error: error!.description)
                }
            }
        }
        _ = sema.wait(timeout: .distantFuture)
    }

    func checkJob(jobId: String, sema: DispatchSemaphore) {
        NSLog("Checking for completion")
        AppDelegate.shared.dropboxManager.dropboxClient!.files.uploadSessionFinishBatchCheck(asyncJobId: jobId).response { status, error in
            if let status = status {
                switch status {
                case .inProgress:
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                        self.checkJob(jobId: jobId, sema: sema)
                    }
                case .complete(let result):
                    self.jobComplete(batchResult: result, sema: sema)
                }
            } else {
                self.logError(error: error!.description)
                sema.signal()
            }
        }

    }

    func jobComplete(batchResult: Files.UploadSessionFinishBatchResult, sema: DispatchSemaphore) {
        // Now we've uploaded all the files, we can connect them to the original assets in core data.
        NSLog("Complete")
        // Really need better error handling
        assert(batchResult.entries.count == assets.count)
        AppDelegate.shared.persistentContainer.performBackgroundTask { context in
            let photos = Photo.insertOrUpdate(self.assets, syncRun: "", into: context)
            for (photo, result) in zip(photos, batchResult.entries) {
                switch result {
                case .success(let fileMetadata):
                    photo.dropboxId = fileMetadata.id
                    photo.dropboxRev = fileMetadata.rev
                    photo.dropboxModified = photo.modified // so we can detect local changes
                    DropboxFile.insertOrUpdate([fileMetadata], syncRun: "", into: context)
                default:
                    fatalError()
                }
            }
            try! context.save()
            sema.signal()
        }
    }

}


// Fetches a PHAsset from iCloud and pushes it to Dropbox as part of a batch start
class UploadStartOperation: Operation {
    // What to push
    let asset: PHAsset

    // The thing that was pushed
    var result: Files.UploadSessionStartResult?
    var bytes: UInt64 = 0

    init(asset: PHAsset) {
        self.asset = asset
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }

        // Get original asset data from photokit
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current // save out edited versions
        options.isSynchronous = true // block operation
        manager.requestImageDataAndOrientation(for: asset, options: options) { [unowned self] data, uti, orientation, info in
            guard !self.isCancelled else { return }

            NSLog("Got original for \(self.asset.localIdentifier)")

            guard let data = data else {
                self.logError(error: "Failed to fetch image \(self.asset.localIdentifier)")
                return
            }

            // Blocking call that uploads to dropbox and counts the bytes
            self.upload(data: data)
        }
        logProgress()
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

}


fileprivate extension PHAsset {
    var dropboxPath: String {

        let datePath: String
        if let creationDate = self.creationDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy/MM"
            dateFormatter.timeZone = TimeZone(identifier: "UTC")
            datePath = dateFormatter.string(from: creationDate)
        } else {
            // no creation date?
            datePath = "No date"
        }

        let filename = (PHAssetResource.assetResources(for: self).first(where: { $0.type == .photo || $0.type == .video })?.originalFilename)!
        return "/\(datePath)/\(filename)"
    }
}
