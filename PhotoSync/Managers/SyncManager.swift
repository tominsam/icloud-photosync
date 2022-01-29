//
//  SyncManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import Foundation
import SwiftyDropbox
import Photos

extension NSNotification.Name {
    static let SyncManagerSyncProgress = NSNotification.Name("SyncManagerSyncProgress")
}

class SyncManager: NSObject {
    private let persistentContainer = AppDelegate.shared.persistentContainer

    var errors: [String] = []

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

        // Sync wants to run in the background
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var cancelled: Bool = false

        persistentContainer.performBackgroundTask { [unowned self] context in
            self.progress.totalUnitCount = Int64(Photo.count(in: context))

            let runIdentifier = UUID().uuidString
            var uploads = [BatchUploader.UploadTask]()
            var deletions = [DeleteOperation.DeleteTask]()

            while !cancelled {

                // fetch the next block of photos that need uploading
                let photos = Photo.matching("uploadRun != %@ OR uploadRun == nil", args: [runIdentifier], limit: 40, in: context)
                if photos.isEmpty {
                    break
                }

                // Bulk fetch assets for this block
                let rawAssets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map { $0.photoKitId }, options: nil)
                let assets = (0..<rawAssets.count).map { rawAssets.object(at: $0) }.uniqueBy(\.localIdentifier)
                let dropboxFiles = DropboxFile.matching("pathLower IN %@", args: [photos.map { $0.path.localizedLowercase }], in: context).uniqueBy(\.pathLower)

                for photo in photos {
                    let asset = assets[photo.photoKitId]
                    let dropboxFile = dropboxFiles[photo.path.localizedLowercase]

                    switch (asset, dropboxFile) {

                    case (.none, .none):
                        // No photokit object, no dropbox object. The local photo object should not exist
                        context.delete(photo)
                        try! context.save()

                    case (.some(let asset), .none):
                        // Object exists in PhotoKit but not in dropbox. Upload it
                        uploads.append(.init(asset: asset, filename: photo.path, existingContentHash: nil))

                    case (.none, .some(let file)):
                        // Object exists in dropbox but not PhotoKit. Delete from Dropbox
                        deletions.append(.init(photoKitId: photo.photoKitId, file: file))

                    case (.some(let asset), .some(let file)):
                        // Object exists in both. Does it need syncing
                        if photo.contentHash != file.contentHash {
                            uploads.append(.init(asset: asset, filename: photo.path, existingContentHash: file.contentHash))
                        }
                    }

                    photo.uploadRun = runIdentifier
                }
                self.progress.completedUnitCount += Int64(photos.count)

                // The uploader also manipulates the photo object, so avoid conflicts by letting go here.
                try! context.save()
                context.reset()

                // NSLog("Accumulated \(uploads.count) uploads and \(deletions.count) deletions")

                if uploads.count >= 20 {

                    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Upload") { [unowned self] in
                        NSLog("Background task is expired")
                        // End the task if time expires.
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                        self.logError(error: "Run out of background time")
                        cancelled = true
                    }

                    BatchUploader(tasks: uploads).run()
                    uploads = []

                    if !cancelled {
                        BatchUploader(tasks: uploads).run()
                        self.progress.completedUnitCount += self.progress.totalUnitCount
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }

                }

                if !deletions.isEmpty {
                    // TODO
                    deletions = []
                }

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: self.progress)
                }

            }

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

    }

}

protocol LoggingOperation {}

extension LoggingOperation {
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
