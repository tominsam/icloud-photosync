//
//  SyncManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation
import SwiftyDropbox
import Photos

extension NSNotification.Name {
    static let SyncManagerSyncProgress = NSNotification.Name("SyncManagerSyncProgress")
}

class SyncManager: NSObject {
    private let persistentContainer = AppDelegate.shared.persistentContainer

    var errors: [String] = []

    private let operationQueue = OperationQueue().configured {
        // TODO dropbox API supports batch upload
        $0.maxConcurrentOperationCount = 1
    }

    // Not using progress on operation queue
    var progress = Progress()

    enum State {
        case notStarted
        case syncing
        case error([String])
        case finished
    }
    public private(set) var state: State = .notStarted

    var canSync: Bool {
        guard case .finished = AppDelegate.shared.dropboxManager.state else {
            return false
        }
        guard case .finished = AppDelegate.shared.photoKitManager.state else {
            return false
        }
        if case .syncing = state {
            return false
        }
        return true
    }

    func logError(error: String) {
        assert(Thread.isMainThread)
        NSLog("SYNC LOGGED ERROR: %@", error)
        errors.append(error)
        NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: progress)
    }

    func logProgress() {
        assert(Thread.isMainThread)
        NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: progress)
    }

    func sync() {
        assert(Thread.isMainThread)
        guard canSync else { return }
        self.state = .syncing
        self.errors.removeAll()
        NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: progress)

        persistentContainer.performBackgroundTask { [unowned self] context in
            var count = 0

            // Walk through the photo database in photoss, it's much faster to fetch the
            // corresponding assets and dropbox files like this.
            let allPhotos = Photo.matching(in: context)
            for photos in allPhotos.chunked(into: 40) {
                // Bulk fetch dropbox files and assets for this photos
                let dropboxFiles = DropboxFile.matching("pathLower IN[c] %@", args: [photos.map { $0.pathLower } ], in: context).uniqueBy(\.pathLower)
                let rawAssets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map { $0.photoKitId }, options: nil)
                let assets = (0..<rawAssets.count).map { rawAssets.object(at: $0) }.uniqueBy(\.localIdentifier)

                let photosForUpload: [BatchUploadOperation.UploadTask] = photos.compactMap { photo in
                    let asset = assets[photo.photoKitId]
                    let dropboxFile = dropboxFiles[photo.pathLower ?? ""] // asset?.dropboxPath.localizedLowercase ??  ?? ""]

                    switch (asset, dropboxFile) {

                    case (.none, .none):
                        // No photokit object, no dropbox object. The local photo object should not exist
                        context.delete(photo)
                        try! context.save()
                        return nil

                    case (.some(let asset), .none):
                        // Object exists in PhotoKit but not in dropbox. Upload it
                        count += 1
                        return .init(asset: asset, existingContentHash: nil)

                    case (.none, .some(let file)):
                        // Object exists in dropbox but not PhotoKit. Delete from Dropbox
                        NSLog("Need to delete remote file \(file.pathLower)")
                        self.operationQueue.addOperation(DeleteOperation(photoKitId: photo.photoKitId, path: file.pathLower, rev: file.rev))
                        return nil

                    case (.some(let asset), .some(let file)):
                        // Object exists in both. Does it need syncing
                        if photo.contentHash == file.contentHash {
                            return nil
                        } else {
                            count += 1
                            return .init(asset: asset, existingContentHash: file.contentHash)
                        }
                    }
                }

                self.progress.totalUnitCount = Int64(count)
                self.progress.becomeCurrent(withPendingUnitCount: Int64(photosForUpload.count))
                self.operationQueue.addOperation(BatchUploadOperation(tasks: photosForUpload))
                self.progress.resignCurrent()

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: self.progress)
                }
            }


            self.operationQueue.addBarrierBlock {
                NSLog("Upload complete")
                if self.errors.isEmpty {
                    self.state = .finished
                } else {
                    self.state = .error(self.errors)
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: self.progress)
                }
            }

            NSLog("Enqueued \(count) operations")
        }

    }


}

extension Operation {
    func logError(error: String) {
        DispatchQueue.main.async {
            AppDelegate.shared.syncManager.logError(error: error)
        }
    }

    func logError<T>(path: String, error: CallError<T>) {
        switch error {
        case .routeError(let boxed, _, _, _):
            if let uploadError = boxed.unboxed as? Files.UploadError {
                logError(error: "Failed to upload \(path): \(uploadError.description)")
            } else if let deleteError = boxed.unboxed as? Files.DeleteError {
                logError(error: "Failed to delete \(path): \(deleteError.description)")
            } else {
                logError(error: "Dropbox error: \(error.description)")
            }
        default:
            logError(error: "Dropbox error: \(error.description)")
        }
    }

    func logProgress() {
        DispatchQueue.main.async {
            AppDelegate.shared.syncManager.logProgress()
        }
    }
}

