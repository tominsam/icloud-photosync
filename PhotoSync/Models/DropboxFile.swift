//
//  DropboxFile.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import Foundation
import CoreData
import SwiftyDropbox


@objc(DropboxFile)
public class DropboxFile: NSManagedObject, ManagedObject {

    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "modified", ascending: false)]
    }

    @NSManaged public var dropboxId: String
    @NSManaged public var path: String?
    @NSManaged public var rev: String
    @NSManaged public var modified: Date?
    @NSManaged public var syncRun: String?
}

extension DropboxFile {


    @discardableResult
    public static func insertOrUpdate(_ metadatas: [Files.FileMetadata], syncRun: String, into context: NSManagedObjectContext) -> [DropboxFile] {
        guard !metadatas.isEmpty else { return [] }
        let existing = DropboxFile.matching("dropboxId IN (%@)", args: [metadatas.map { $0.id }], in: context).uniqueBy(\.dropboxId)
        return metadatas.map { metadata in
            let file = existing[metadata.id] ?? context.insertObject()
            file.update(from: metadata)
            file.syncRun = syncRun
            return file
        }
    }

    func update(from metadata: Files.FileMetadata) {
        dropboxId = metadata.id
        path = metadata.pathLower
        rev = metadata.rev
        modified = metadata.serverModified
    }

}
