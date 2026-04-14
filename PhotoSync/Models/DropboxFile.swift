// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
@preconcurrency import SwiftyDropbox

// Protocol allows mocking for tests
protocol DropboxFileProtocol {
    var pathLower: String { get }
    var rev: String { get }
    var contentHash: String { get }
}

/// Represents a local cache of the state of a file in dropbox. We need this because we don't want
/// to fetch every single file via the pagination API every time, the continuation API is very fast.
/// However it's a matter of a minute or so to refresh everything, so this table is not particularly
/// important - we can lose it and replace it easily.
@objc(DropboxFile)
class DropboxFile: NSManagedObject, ManagedObject, DropboxFileProtocol {
    static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "modified", ascending: false)]
    }

    // All these properties are directly from the API, no local calculations
    @NSManaged var dropboxId: String
    @NSManaged var pathLower: String
    @NSManaged var rev: String
    @NSManaged var contentHash: String
    @NSManaged var modified: Date?
}

extension DropboxFile {
    @discardableResult
    static func insertOrUpdate(
        _ metadatas: [Files.FileMetadata],
        delete deletedMetadatas: [Files.DeletedMetadata],
        into context: NSManagedObjectContext
    ) throws -> [DropboxFile] {
        // Mechanics here are from https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
        // "For each FileMetadata, store the new entry at the given path in your local
        // state. [..] If there's already something else at the given path, replace
        // it [..] For each DeletedMetadata, if your local state has something at the
        // given path, remove it [..] If there's nothing at the given path, ignore this entry."
        
        let files: [DropboxFile]
        if !metadatas.isEmpty {
            // Process the batch of metadatas (up to 2000 objects)
            // Fetch every existing DB object we have for these files, make a dict
            // of path -> object
            let existing = try DropboxFile.matching(
                "pathLower IN (%@)",
                args: [metadatas.map { $0.pathLower! }],
                in: context
            ).uniqueBy(\.pathLower)

            // For every returned file in order...
            files = metadatas.compactMap { metadata -> DropboxFile? in
                guard let path = metadata.pathLower else { return nil }
                // Get the existing DropboxFile or create a new one
                let file = existing[path] ?? context.insertObject()
                // Update the local object state from the API
                file.update(from: metadata)
                return file
            }
            
            // We don't bother tracking if we changed anything. If there was an API call at all,
            // the cost of going to the network dwarfs the cost of just blindly saving the context.
            try context.save(andReset: true)
        } else {
            files = []
        }

        if !deletedMetadatas.isEmpty {
            // Deletes must be applied after inserts and updated (the API could presumably
            // create, update, and delete a file in a single paged response)
            let newExisting = try DropboxFile.matching(
                "pathLower IN (%@)",
                args: [deletedMetadatas.map { $0.pathLower! }],
                in: context
            ).uniqueBy(\.pathLower)

            deletedMetadatas.forEach { deleted in
                if let path = deleted.pathLower, let file = newExisting[path] {
                    context.delete(file)
                }
            }
            try context.save(andReset: true)
        }

        return files
    }

    /// Fetch a file by path. Dropbox file path are case-insensitive.
    static func forPath(_ pathLower: String, context: NSManagedObjectContext) throws -> DropboxFile? {
        return try DropboxFile.matching("pathLower ==[c] %@", args: [pathLower], in: context).first
    }

    /// Delete all files (for cursor reset)
    static func deleteAll(in context: NSManagedObjectContext) throws {
        // not very efficient.
        for file in try DropboxFile.matching(nil, in: context) {
            context.delete(file)
        }
        try context.save(andReset: true)
    }

    internal func update(from metadata: Files.FileMetadata) {
        dropboxId = metadata.id
        pathLower = metadata.pathLower!
        rev = metadata.rev
        modified = metadata.serverModified
        contentHash = metadata.contentHash!
    }
}
