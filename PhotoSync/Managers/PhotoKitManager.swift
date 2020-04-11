//
//  PhotoKitManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import Photos
import CoreData

extension NSNotification.Name {
    static let PhotoKitManagerSyncComplete = NSNotification.Name("PhotoKitManagerSyncComplete")
    static let PhotoKitManagerSyncProgress = NSNotification.Name("PhotoKitManagerSyncProgress")
}

class PhotoKitManager: NSObject {

    let persistentContainer: NSPersistentContainer = AppDelegate.shared.persistentContainer

    // Arbitrary identifier for this run
    private let runIdentifier = UUID().uuidString

    // Lock so that we don't try to sync photos more than once at a time
    public private(set) var syncing: Bool = false
    public let progress = Progress()

    // returns false if the user has explicitly denied photos permission
    var isDenied: Bool {
        switch PHPhotoLibrary.authorizationStatus() {
        case .denied:
            return true
        default:
            return false
        }
    }

    lazy var allPhotos: PHFetchResult<PHAsset> = {
        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.includeHiddenAssets = false
        allPhotosOptions.wantsIncrementalChangeDetails = true
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: allPhotosOptions)
    }()

    override init() {
        super.init()
        //PHPhotoLibrary.shared().register(self)
    }

    func sync() {
        guard !syncing else { return }
        syncing = true

        persistentContainer.performBackgroundTask { context in
            let start = DispatchTime.now()

            let count = self.allPhotos.count
            NSLog("got \(count) photos")

            /*
             The PhotoKit API is very very fast - updating the Photo objects in code data is the bottleneck here.
             So I've written the Photo.update call to take lists of assets, because the predicate "where ID IN (?)"
             is much faster than calling "where ID == ?" for each element in the array. So this loop will fetch
             blocks of 200 photos at once from PhotoKit. It's considerably faster than updating a single image
             at a time, and this loop is the tine critical part of the iCloud photo sync.

             I also periodically save and flush the context. Do this too often and you're spending all your
             time writing to disk. Do little and the unsaved changes in the context build up and slow the process
             down.

             The step size and the flush batch size are chosen here based on my device (iPhone 11) saving about 50k
             photos from my local library, where I get about 15k photos per second written into the data store.
             */

            let fetchSize = 400
            self.progress.totalUnitCount = Int64(count)
            for index in stride(from: 0, to: count, by: fetchSize) {
                if index > 0 && index % 2_000 == 0 {
                    try! context.save()
                    context.reset()
                }

                if index % 10_000 == 0 {
                    NSLog("Synced \(index) photos")
                    DispatchQueue.main.async {
                        self.progress.completedUnitCount = Int64(index)
                        NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: self.progress)
                    }
                }

                let top = min(count, index + fetchSize)
                let assets = self.allPhotos.objects(at: IndexSet(integersIn: index..<top))
                Photo.insertOrUpdate(assets, syncRun: self.runIdentifier, into: context)
            }

            // Wasteful perhaps, but we spot deleted photos by geenrating a random "run identifier"
            // and updating every photo we've seen in this sycn with that identifier. Therefore every
            // photo left in the database _without_ that run identifier wasn't seen this time, and has
            // been deleted since our last sync
            let removed = Photo.matching(predicate: "syncRun != %@", args: [self.runIdentifier], in: context)
            if !removed.isEmpty {
                NSLog("Removing \(removed.count) deleted photo(s)")
                for photo in removed {
                    photo.markRemoved()
                    photo.syncRun = self.runIdentifier
                }
            }

            try! context.save()
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            NSLog("Synced %d photos in %0.1f seconds (%.0f per second)", count, duration, Double(count) / duration)

            DispatchQueue.main.async {
                self.syncing = false
                self.progress.completedUnitCount = self.progress.totalUnitCount
                NotificationCenter.default.post(name: .PhotoKitManagerSyncComplete, object: self.progress)
            }
        }
    }
}

extension PhotoKitManager: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {

        // There seems to be a bug here where deleted photos don't count as
        // intereesting? Sometimes deletions don't make it through this gate
        // at all. Sometimes they do, but then they immediately appear as created
        // again. Either way, I don't really trust this live updating thing
        // at all. Luckily it's not vital to the operation of the app - I'm
        // ok with syncing on startup given how fast sync is.

        guard let changes = changeInstance.changeDetails(for: allPhotos) else {
            NSLog("Boring photo changes")
            return
        }

        guard changes.hasIncrementalChanges else {
            NSLog("Photo changes are not incremental!")
            sync()
            return
        }

        persistentContainer.performBackgroundTask { context in
            if !changes.removedObjects.isEmpty {
                NSLog("Deleted photos \(changes.removedObjects)")
                Photo.delete(changes.removedObjects, syncRun: self.runIdentifier, in: context)
            }
            if !changes.insertedObjects.isEmpty {
                NSLog("Seen new photo \(changes.insertedObjects)")
                Photo.insertOrUpdate(changes.insertedObjects, syncRun: self.runIdentifier, into: context)
            }
            if !changes.changedObjects.isEmpty {
                NSLog("Seen changed photos \(changes.changedObjects)")
                Photo.insertOrUpdate(changes.changedObjects, syncRun: self.runIdentifier, into: context)
            }
            try! context.save()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .PhotoKitManagerSyncComplete, object: nil)
            }
        }

    }
}


