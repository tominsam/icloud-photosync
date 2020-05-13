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
    static let PhotoKitManagerSyncProgress = NSNotification.Name("PhotoKitManagerSyncProgress")
}

class PhotoKitManager: NSObject {

    let persistentContainer = AppDelegate.shared.persistentContainer

    // Lock so that we don't try to sync photos more than once at a time
    enum State {
        case notStarted
        case syncing
        case finished
    }
    public private(set) var state: State = .notStarted
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

//    lazy var allPhotos: PHFetchResult<PHAsset> = {
//        let allPhotosOptions = PHFetchOptions()
//        allPhotosOptions.includeHiddenAssets = false
//        allPhotosOptions.wantsIncrementalChangeDetails = true
//        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
//        return PHAsset.fetchAssets(with: allPhotosOptions)
//    }()

    override init() {
        super.init()
        //PHPhotoLibrary.shared().register(self)
    }

    func sync() {
        assert(Thread.isMainThread)
        if case .syncing = state {
            NSLog("Already syncing photos")
            return
        }
        state = .syncing

        persistentContainer.performBackgroundTask { [unowned self] context in
            let start = DispatchTime.now()

            let allPhotosOptions = PHFetchOptions()
            allPhotosOptions.includeHiddenAssets = false
            allPhotosOptions.wantsIncrementalChangeDetails = true
            allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let allPhotos = PHAsset.fetchAssets(with: allPhotosOptions)

            let count = allPhotos.count
            NSLog("Phone has \(count) photo(s)")

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

                if index % 4_000 == 0 {
                    if index > 0 {
                        NSLog("Synced \(index) photos")
                    }
                    DispatchQueue.main.async { [unowned self] in
                        self.progress.completedUnitCount = Int64(index)
                        NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: self.progress)
                    }
                }

                let top = min(count, index + fetchSize)
                let assets = allPhotos.objects(at: IndexSet(integersIn: index..<top))
                Photo.insertOrUpdate(assets, into: context)
            }

            try! context.save()
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            NSLog("Synced %d photos in %0.1f seconds (%.0f per second)", count, duration, Double(count) / duration)

            DispatchQueue.main.async { [unowned self] in
                self.state = .finished
                self.progress.completedUnitCount = self.progress.totalUnitCount
                NotificationCenter.default.post(name: .PhotoKitManagerSyncProgress, object: self.progress)
            }
        }
    }
}

