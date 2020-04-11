//
//  Photo.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import CoreData
import Photos

extension Photo: ManagedObject {

    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "created", ascending: false)]
    }

    @discardableResult
    public static func insertOrUpdate(_ assets: [PHAsset], syncRun: String, into context: NSManagedObjectContext) -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = Photo.matching(predicate: "photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.map { asset in
            let photo = existing[asset.localIdentifier] ?? context.insertObject()
            photo.update(from: asset)
            photo.syncRun = syncRun
            return photo
        }
    }

    @discardableResult
    public static func delete(_ assets: [PHAsset], syncRun: String, in context: NSManagedObjectContext) -> [Photo] {
        guard !assets.isEmpty else { return [] }
        let existing = Photo.matching(predicate: "photoKitId IN (%@)", args: [assets.map { $0.localIdentifier }], in: context).uniqueBy(\.photoKitId)
        return assets.compactMap { asset in
            guard let photo = existing[asset.localIdentifier] else {
                NSLog("Can't delete photo \(asset.localIdentifier)")
                return nil
            }
            photo.markRemoved()
            photo.syncRun = syncRun
            return photo
        }
    }

    func update(from asset: PHAsset) {
        photoKitId = asset.localIdentifier
        created = asset.creationDate
        modified = asset.modificationDate
    }

    func markRemoved() {
        removedFromServer = true
        modified = Date()
    }

}
