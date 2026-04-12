// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import Photos
import SwiftyDropbox
import UIKit

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
        var state = progressManager.createTask(named: "Dropbox", total: nil)

        // Try to resume a previous run if possible
        var cursor = try await database.perform { context in
            (try SyncToken.dataFor(type: .dropboxListFolder, in: context) as NSString?) as String?
        }

        // If the cursor is nil, we've never fetched a page, get the first page as a bootstrap
        if cursor == nil {
            NSLog("%@", "Dropbox cursor is missing or invalid - resetting local sync state")

            // We don't have an existing cursor for this. First remove everything
            try await database.perform { context in
                try DropboxFile.deleteAll(in: context)
            }
            state.progress = 0

            // Now get the first page of results (DB has a cursor-based pagination API for
            // large results, and this is probably a large result). Path is "" - this isn't
            // the root of the Dropbox, this is the root of the app-specific folder we own.
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolder(path: "", recursive: true, includeDeleted: true, limit: 2000).asyncResponse()
            } catch {
                recordError("Error calling dropbox listFolder: \(error.localizedDescription)")
                throw error
            }
            cursor = try await insertPage(listResult, state: &state)
        } else {
            // This is a guess, of course - we don't get a count from DB
            // at any point, so the best number we have is "the last number"
            let count = await database.perform { context in
                DropboxFile.count(in: context)
            }
            state.progress = count
        }
        NSLog("Cursor is %@", String(describing: cursor))

        // While there are more results, fetch and insert the next page
        while cursor != nil {
            let listResult: Files.ListFolderResult
            do {
                listResult = try await dropboxClient.files.listFolderContinue(cursor: cursor!).asyncResponse()
            } catch {
                recordError("Error calling dropbox listFolderContinue: \(error.localizedDescription)")
                throw error
            }
            cursor = try await insertPage(listResult, state: &state)
            if !listResult.hasMore {
                NSLog("All files fetched from dropbox")
                break
            }
        }

        NSLog("%@", "File sync complete")
        state.setComplete()
    }

    func insertPage(_ listResult: Files.ListFolderResult, state: inout TaskProgress) async throws -> String {
        // There are also folders in this list but they're unimportant
        let fileMetadata = listResult.entries.compactMap { $0 as? Files.FileMetadata }
        let deletedMetadata = listResult.entries.compactMap { $0 as? Files.DeletedMetadata }
        NSLog("%@", "Inserting / updating \(fileMetadata.count) file(s), deleting \(deletedMetadata.count) file(s)")
        try await database.perform { context in
            try DropboxFile.insertOrUpdate(fileMetadata, delete: deletedMetadata, into: context)
            try SyncToken.insertOrUpdate(type: .dropboxListFolder, value: listResult.cursor as NSString, into: context)
        }
        state.progress += fileMetadata.count
        return listResult.cursor
    }

}
