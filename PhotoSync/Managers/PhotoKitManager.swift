// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Photos
import UIKit

@MainActor
class PhotoKitManager {
    let database: Database
    let progressManager: ProgressManager
    private let errorUpdate: (ServiceError) -> Void

    init(database: Database, progressManager: ProgressManager, errorUpdate: @escaping (ServiceError) -> Void) {
        self.database = database
        self.progressManager = progressManager
        self.errorUpdate = errorUpdate
    }

    static var hasPermission: Bool {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    func recordError(_ message: String, path: String = "/", error: Error? = nil) {
        errorUpdate(ServiceError(path: path, message: message, error: error))
    }

    func sync() async {
        do {
            try await internalSync()
        } catch {
            recordError(error.localizedDescription)
        }
    }
    
    func internalSync() async throws {
        let count = await database.perform { Photo.count(in: $0) }
        let state = progressManager.createTask(named: "Local photos", total: count)
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
        
        let allAssets = await PHAsset.allAssets
        
        // First sync is slow because we have no photo paths, and those are expensive,
        // so it's better to update more frequently, later syncs are bound by DB insert
        // rate, and larger blocks are more efficient.
        let fetchSize = firstSync ? 200 : 1000
        state.total = allAssets.count
        
        try await database.perform { context in
            
            for chunk in allAssets.chunked(into: fetchSize) {
                state.progress += chunk.count
                let (_, changed) = try Photo.insertOrUpdate(chunk, into: context)
                if changed {
                    try context.save(andReset: true)
                }
            }
            
            let deleteMe: Set<String> = Set(
                // Everything in the database
                try Photo.matching(nil, in: context).map { $0.photoKitId }
            ).subtracting(
                // minus everything in photokit
                allAssets.map { $0.localIdentifier }
            )
            for localIdentifier in deleteMe {
                if let photo = try Photo.forLocalIdentifier(localIdentifier, in: context) {
                    context.delete(photo)
                }
            }
            try context.save(andReset: true)
        }
        state.setComplete()
    }
}
