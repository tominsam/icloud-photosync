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

    var allAssets: [PHAsset] = []

    func sync() async throws {
        let start = DispatchTime.now()

        let context = persistentContainer.newBackgroundContext()
        let count = Photo.count(in: context)
        await setProgress(0, total: count, named: "Local photos")
        let firstSync = count == 0

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
        allAssets = await PHAsset.allAssets

        // First sync is slow because we have no photo paths, and those are expensive,
        // so it's better to update more frequently, later syncs are bound by DB insert
        // rate, and larger blocks are more efficient.
        let fetchSize = firstSync ? 200 : 1000
        await setProgress(0, total: allAssets.count, named: "Local photos")
        var progress = 0

        for chunk in allAssets.chunked(into: fetchSize) {
            try await Photo.insertOrUpdate(chunk, into: context)
            try await context.performSave(andReset: true)
            progress += chunk.count
            await setProgress(progress, total: allAssets.count, named: "Local photos")
        }

        let deleteMe: Set<String> = Set(
            // Everything in the database
            try await Photo.matching(nil, in: context).map { $0.photoKitId }
        ).subtracting(
            // minus everything in photokit
            allAssets.map { $0.localIdentifier }
        )
        for localIdentifier in deleteMe {
            if let photo = try await Photo.forLocalIdentifier(localIdentifier, in: context) {
                context.delete(photo)
            }
        }
        try await context.performSave(andReset: true)

        let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        NSLog("Synced %d photos in %0.1f seconds (%.0f per second)", allAssets.count, duration, Double(allAssets.count) / duration)
        await markComplete(allAssets.count, named: "Local photos")
    }
}
