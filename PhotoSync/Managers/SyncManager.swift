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

    private var dropboxManager = AppDelegate.shared.dropboxManager
    private var photoKitManager = AppDelegate.shared.photoKitManager

    var errors: [String] = []

    let operationQueue = OperationQueue().configured {
        // TODO dropbox API supports batch upload
        $0.maxConcurrentOperationCount = 1
    }

    var progress: Progress { operationQueue.progress }

    enum State {
        case notStarted
        case syncing
        case error([String])
        case finished
    }
    public private(set) var state: State = .notStarted

    var canSync: Bool {
        guard case .finished = dropboxManager.state else {
            return false
        }
        guard case .finished = photoKitManager.state else {
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
        NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: operationQueue.progress)
    }

    func logProgress() {
        assert(Thread.isMainThread)
        NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: operationQueue.progress)
    }

    func sync() {
        assert(Thread.isMainThread)
        guard canSync else { return }
        self.state = .syncing
        self.errors.removeAll()
        // First cut estimate
        self.operationQueue.progress.totalUnitCount = Int64(Photo.matching(in: persistentContainer.viewContext).count)
        NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: operationQueue.progress)

        persistentContainer.performBackgroundTask { [unowned self] context in
            var count = 0

            DispatchQueue.main.async {
                self.logError(error: "goo")
            }

            // Walk through the photo database in chunks, it's much faster to fetch the
            // corresponding assets and dropbox files like this.
            let allPhotos = Photo.matching(in: context)
            for chunk in allPhotos.chunked(into: 200) {
                // Bulk fetch dropbox files and assest for this chunk
                let dropboxFiles = DropboxFile.matching("dropboxId IN %@", args: [chunk.map { $0.dropboxId } ], in: context).uniqueBy(\.dropboxId)
                let rawAssets = PHAsset.fetchAssets(withLocalIdentifiers: chunk.map { $0.photoKitId }, options: nil)
                let assets = (0..<rawAssets.count).map { rawAssets.object(at: $0) }.uniqueBy(\.localIdentifier)

                for photo in chunk {
                    let dropboxFile = photo.dropboxId == nil ? nil : dropboxFiles[photo.dropboxId!]

                    // If there photo is deleted locally, make sure it's also not in dropbox
                    guard let asset = assets[photo.photoKitId] else {
                        if let dropboxFile = dropboxFile, let path = dropboxFile.path {
                            self.operationQueue.addOperation(DeleteOperation(photoKitId: photo.photoKitId, path: path, rev: dropboxFile.rev))
                            count += 1
                        } else {
                            // possible (delete from both places)
                            context.delete(photo)
                            try! context.save()
                        }
                        continue
                    }

                    if let dropboxFile = dropboxFile, photo.dropboxRev == dropboxFile.rev {
                        // Local file rev matches dropbox file rev, so we can assume it's unchanged.
                        continue
                    }

                    // Images only for now
                    switch asset.mediaType {
                    case .image:
                        self.operationQueue.addOperation(UploadOperation(asset: asset))
                        count += 1
                    default:
                        NSLog("Skipping media type \(asset.mediaType)")
                        break
                    }
                }

            }

            self.operationQueue.progress.totalUnitCount = Int64(count)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: self.operationQueue.progress)
            }

            self.operationQueue.addBarrierBlock {
                NSLog("Upload complete")
                if self.errors.isEmpty {
                    self.state = .finished
                } else {
                    self.state = .error(self.errors)
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .SyncManagerSyncProgress, object: self.operationQueue.progress)
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



class UploadOperation: Operation {
    let asset: PHAsset

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
        options.isSynchronous = true
        manager.requestImageDataAndOrientation(for: asset, options: options) { [unowned self] data, uti, orientation, info in
            NSLog("Got original for \(self.asset.localIdentifier)")
            guard !self.isCancelled else {
                return
            }

            guard let data = data, let uti = uti else {
                self.logError(error: "Failed to fetch image \(self.asset.localIdentifier)")
                return
            }

            // TODO Need to handle duplicate filenames in a month and yet still be able to overwrite
            // remote files that were changed outside of this client
            let path = self.asset.wantedDropboxPath(uti: uti)
            self.upload(data: data, to: path, modified: self.asset.creationDate ?? self.asset.modificationDate)
        }
        logProgress()
    }

    func upload(data: Data, to path: String, modified: Date?) {
        let sema = DispatchSemaphore(value: 0)
        NSLog("Uploading to \(path)")

        AppDelegate.shared.dropboxManager.dropboxClient?.files.upload(path: path, mode: .overwrite, clientModified: modified, input: data).response { file, error in

            guard !self.isCancelled else {
                sema.signal()
                return
            }

            if let error = error {
                self.logError(path: path, error: error)
            } else if let file = file {
                NSLog("Uploaded \(path)")
                let context = AppDelegate.shared.persistentContainer.viewContext
                if let photo = Photo.matching("photoKitId = %@", args: [self.asset.localIdentifier], in: context).first {
                    photo.dropboxId = file.id
                    photo.dropboxRev = file.rev
                    DropboxFile.insertOrUpdate([file], syncRun: "", into: context)
                    try! photo.managedObjectContext!.save()
                } else {
                    fatalError("No photo for local identifier \(self.asset.localIdentifier)")
                }
            }
            sema.signal()

        }

        _ = sema.wait(timeout: .distantFuture)
        logProgress()
    }

}


class DeleteOperation: Operation {
    let photoKitId: String
    let path: String
    let rev: String

    init(photoKitId: String, path: String, rev: String) {
        self.photoKitId = photoKitId
        self.path = path
        self.rev = rev
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        let sema = DispatchSemaphore(value: 0)

        AppDelegate.shared.dropboxManager.dropboxClient?.files.deleteV2(path: path, parentRev: rev).response { [unowned self] result, error in
            if let error = error {
                self.logError(path: self.path, error: error)
            } else {
                NSLog("Deleted \(self.path)")
                // It's neither in the local store or the remote. We can remove it from the database
                let context = AppDelegate.shared.persistentContainer.viewContext
                if let photo = Photo.matching("photoKitId = %@", args: [self.photoKitId], in: context).first {
                    context.delete(photo)
                    try! photo.managedObjectContext!.save()
                }
            }
            sema.signal()
        }

        _ = sema.wait(timeout: .distantFuture)
        logProgress()
    }
}


fileprivate extension PHAsset {
    func wantedDropboxPath(uti: String) -> String {

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
