// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

/// Fetches all files from Dropbox and stores the files, and their content hashes, into the local database. Maintains
/// a cursor - syncs on later runs of the app will do incremental updates rather than fetching everything, so they
/// will be very fast. The Dropbox API sync cursors have very long lifetimes (possibly unlimited?)
@MainActor
class DropboxManager {
    let database: Database
    let dropboxClient: DropboxClient
    let progressManager: ProgressManager
    private let errorUpdate: (ServiceError) -> Void

    func recordError(_ message: String, path: String = "/", error: Error? = nil) {
        errorUpdate(ServiceError(path: path, message: message, error: error))
    }

    init(database: Database, dropboxClient: DropboxClient, progressManager: ProgressManager, errorUpdate: @escaping (ServiceError) -> Void) {
        self.database = database
        self.dropboxClient = dropboxClient
        self.progressManager = progressManager
        self.errorUpdate = errorUpdate
    }

    func sync() async {
        do {
            try await internalSync()
        } catch {
            recordError(error.localizedDescription)
        }
    }
    
    func internalSync() async throws {
        // The dropbox API doesn't ever return the total file count.
        let state = progressManager.createTask(named: "Dropbox", total: nil)

        // Try to resume a previous run if possible
        let lastCursor = try await database.perform { context in
            (try SyncToken.dataFor(type: .dropboxListFolder, in: context) as NSString?) as String?
        }

        var cursor: String
        
        if let lastCursor {
            cursor = lastCursor
        } else {
            // If the cursor is nil, we've never fetched a page, get the first page as a bootstrap
            NSLog("%@", "Dropbox cursor is missing or invalid - resetting local sync state")

            // We don't have an existing cursor for this. First remove everything
            try await database.perform { context in
                try DropboxFile.deleteAll(in: context)
            }

            // Now get the first page of results (DB has a cursor-based pagination API for
            // large results, and this is probably a large result). Path is "" - this isn't
            // the root of the Dropbox, this is the root of the app-specific folder we own.
            // The later "continue" calls we make want only the cursor parameter - the cursor
            // encodes all the parameters.
            do {
                let listResult = try await dropboxClient.files.listFolder(
                    path: "", // app folder
                    recursive: true,
                    includeDeleted: true, // important for sync in later runs
                    limit: 2000
                ).asyncResponse()
                cursor = try await insertPage(listResult)
            } catch {
                recordError("Error calling dropbox listFolder: \(error.localizedDescription)")
                throw error
            }
        }

        // Start progress at the current number of files we have
        state.progress = await database.perform { DropboxFile.count(in: $0) }

        // While there are more results, fetch and insert the next page
        while true {
            let listResult = try await dropboxClient.files.listFolderContinue(cursor: cursor).asyncResponse()
            cursor = try await insertPage(listResult)
            // This is not free, but much cheaper than the insert or fetch, so it's not remotely
            // the bottleneck, and it means that the count is always the number of files we actually
            // have - counting sync entries is complicated because some are updates / deletes
            state.progress = await database.perform { DropboxFile.count(in: $0) }
            if !listResult.hasMore {
                NSLog("All files fetched from dropbox")
                break
            }
        }

        NSLog("%@", "File sync complete")
        state.setComplete()
    }

    func insertPage(_ listResult: Files.ListFolderResult) async throws -> String {
        // There are also folders in this list but they're unimportant
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }
        let deletedMetadata = listResult.entries.compactMap { $0 as? Files.DeletedMetadata }
        NSLog("%@", "Inserting / updating \(fileMetadata.count) file(s), deleting \(deletedMetadata.count) file(s)")
        try await database.perform { context in
            try DropboxFile.insertOrUpdate(fileMetadata, delete: deletedMetadata, into: context)
            try SyncToken.insertOrUpdate(type: .dropboxListFolder, value: listResult.cursor as NSString, into: context)
        }
        return listResult.cursor
    }

}
