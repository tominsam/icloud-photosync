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

class PhotoKitManager: Manager {

    static var hasPermission: Bool {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    func sync() async throws {
        let start = DispatchTime.now()

        let context = persistentContainer.newBackgroundContext()
        let count = Photo.count(in: context)
        await setTotal(count)
        let firstSync = count == 0

        // If the user deletes one of of a pair of files with the same name,
        // I want to restore the original name to whichever is left - that means
        // that the path generation code needs to be safe, and return the same
        // result when called repeatedly on the same data set, but also generate
        // new data when called on a new dataset. (And be consistent cross-platform)
        // That's done by having every Photo have a cached "this is the path that
        // I want" that is expensive to calculate, then on parse we loop through
        // the photos in a _consistent order_ and generate the actual output paths.
        // This should be deterministic when you leave both files in place.
        NSLog("%@", "Resetting paths")
        try Photo.clearCalculatedPaths(in: context)

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

        NSLog("%@", "Getting photos")
        let allPhotos = await PHAsset.allAssets

        // First sync is slow because we have no photo paths, and those are expensive,
        // so it's better to update more frequently, later syncs are bound by DB insert
        // rate, and larger blocks are more efficient.
        let fetchSize = firstSync ? 200 : 1000
        await setTotal(allPhotos.count)

        for chunk in allPhotos.chunked(into: fetchSize) {
            await addProgress(fetchSize)
            try await Photo.insertOrUpdate(chunk, into: context)
            try await context.performSave(andReset: true)
        }

        let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        NSLog("Synced %d photos in %0.1f seconds (%.0f per second)", allPhotos.count, duration, Double(allPhotos.count) / duration)
        await markComplete()
    }
}
