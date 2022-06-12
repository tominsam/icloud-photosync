//
//  PhotoKitManager.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Photos
import UIKit

class PhotoKitManager {
    private let persistentContainer: NSPersistentContainer
    let progressUpdate: @MainActor(ServiceState) -> Void

    private var state: ServiceState?

    static var hasPermission: Bool {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    init(persistentContainer: NSPersistentContainer, progressUpdate: @escaping (ServiceState) -> Void) {
        self.persistentContainer = persistentContainer
        self.progressUpdate = progressUpdate
    }

    func sync() async throws {
        if state != nil {
            NSLog("%@", "Already syncing photos")
            return
        }
        state = ServiceState()

        let start = DispatchTime.now()

        /*
         The PhotoKit API is very very fast - updating the Photo objects in core data is the bottleneck here.
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

        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.includeHiddenAssets = false
        allPhotosOptions.wantsIncrementalChangeDetails = true
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // This blocks very briefly - 0.2 seconds on my physical
        // device for 70k photos - so I'm not super bothered right now.
        let allPhotos = PHAsset.fetchAssets(with: allPhotosOptions)

        let count = allPhotos.count
        NSLog("%@", "Phone has \(count) photo(s)")

        let fetchSize = 400
        state?.total = count

        for index in stride(from: 0, to: count, by: fetchSize) {
            state!.progress = index
            await progressUpdate(state!)

            let top = min(count, index + fetchSize)
            let assets = allPhotos.objects(at: IndexSet(integersIn: index ..< top))

            let context = persistentContainer.newBackgroundContext()
            try await Photo.insertOrUpdate(assets, into: context)
            try await context.perform {
                try context.save()
                context.reset()
            }
        }

        let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        NSLog("Synced %d photos in %0.1f seconds (%.0f per second)", count, duration, Double(count) / duration)

        state?.complete = true
        let total = state?.total ?? 0
        state?.progress = total
        await progressUpdate(state!)
    }
}
