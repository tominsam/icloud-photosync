//
//  DropboxFile.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/11/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData
import Foundation
import SwiftyDropbox

@objc(DropboxFile)
public class DropboxFile: NSManagedObject, ManagedObject {
    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "modified", ascending: false)]
    }

    @NSManaged public var dropboxId: String
    @NSManaged public var pathLower: String
    @NSManaged public var rev: String
    @NSManaged public var contentHash: String
    @NSManaged public var modified: Date?
    @NSManaged public var syncRun: String?
    @NSManaged public var uploadRun: String?
}

public extension DropboxFile {
    @discardableResult
    static func insertOrUpdate(_ metadatas: [Files.FileMetadata], syncRun: String, into context: NSManagedObjectContext) -> [DropboxFile] {
        guard !metadatas.isEmpty else { return [] }
        let existing = DropboxFile.matching("pathLower IN (%@)", args: [metadatas.map { $0.pathLower! }], in: context).uniqueBy(\.pathLower)
        return metadatas.map { metadata in
            let file = existing[metadata.pathLower!] ?? context.insertObject()
            file.update(from: metadata)
            file.syncRun = syncRun
            return file
        }
    }

    static func forPath(_ pathLower: String, context: NSManagedObjectContext) -> DropboxFile? {
        return DropboxFile.matching("pathLower ==[c] %@", args: [pathLower], in: context).first
    }

    internal func update(from metadata: Files.FileMetadata) {
        dropboxId = metadata.id
        pathLower = metadata.pathLower!
        rev = metadata.rev
        modified = metadata.serverModified
        contentHash = metadata.contentHash!
    }
}
