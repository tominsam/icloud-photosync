//  Copyright 2020 Thomas Insam. All rights reserved.

import CollectionConcurrencyKit
import CoreData
import Photos
import SwiftyDropbox
import UIKit

enum UploadError: Error {
    case photoKit(String)
    case dropbox(String)
}

// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
class BatchUploader: LoggingOperation {
    struct UploadTask {
        let asset: PHAsset
        let filename: String
        let existingContentHash: String?
    }

    enum UploadResult {
        case success(String, Files.UploadSessionFinishArg)
        case unchanged
        case failure(path: String, message: String)
    }

    enum FinishResult {
        case success(Files.FileMetadata)
        case unchanged
        case failure(path: String, message: String)
    }

    static func batchUpload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, tasks: [UploadTask]) async throws -> [FinishResult] {
        // concurrently upload all the files
        let uploadResults = try await withThrowingTaskGroup(of: UploadResult.self) { group -> [UploadResult] in
            for task in tasks {
                group.addTask {
                    do {
                        if let uploadSession = try await upload(persistentContainer: persistentContainer, dropboxClient: dropboxClient, task: task) {
                            return .success(task.filename, uploadSession)
                        } else {
                            return .unchanged
                        }
                    } catch {
                        return .failure(path: task.filename, message: error.localizedDescription)
                    }
                }
            }
            var output = [UploadResult]()
            for try await value in group {
                output.append(value)
            }
            return output
        }

        let finishResults = try await finish(dropboxClient: dropboxClient, entries: uploadResults)
        try await jobComplete(persistentContainer: persistentContainer, finishResults: finishResults)

        return finishResults
    }

    private static func upload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, task: BatchUploader.UploadTask) async throws -> Files.UploadSessionFinishArg? {
        // Get photo from photoKit
        NSLog("%@", "Downloading \(task.filename)")
        let data = try await task.asset.getImageData()

        // This should be async, it's potentially reading hundreds of megs off disk,
        // but in practice it seems to be really really fast, so it's not a priority
        guard let hash = data.dropboxContentHash() else {
            throw UploadError.photoKit("Can't hash image contents for \(task.filename)")
        }

        // Store the content hash on the database object before we start the upload
        let context = persistentContainer.newBackgroundContext()
        try await context.perform {
            if let photo = Photo.forAsset(task.asset, in: context) {
                // if the photo modified date changed, we should have niled this. If it's set,
                // but different, that's a profound problem with the sync engine and I need to know
                assert(photo.contentHash == nil || photo.contentHash == hash)
                photo.contentHash = hash
                try context.save()
            }
        }

        // Skip the upload if the file is unchanged
        if task.existingContentHash == hash {
            return nil
        }

        // Upload the file to dropbox. This needs to be "finished", but we do that in batches.
        NSLog("%@", "Uploading \(task.filename) with \(hash) replacing \(task.existingContentHash ?? "nil")")
        switch data {
        case let .data(data):
            return try await uploadData(dropboxClient: dropboxClient, task: task, data: data)
        case let .url(url):
            return try await uploadUrl(dropboxClient: dropboxClient, task: task, url: url)
        }
    }

    static func uploadData(dropboxClient: DropboxClient, task: BatchUploader.UploadTask, data: Data) async throws -> Files.UploadSessionFinishArg {
        // Theoretically if data is >150mb we have a problem here, but that seems unlikely
        // for most use cases right now. (hahahaha yes I know)
        let length = data.count
        let result = try await dropboxClient.files.uploadSessionStart(close: true, input: data).asyncResponse()
        let cursor = Files.UploadSessionCursor(
            sessionId: result.sessionId,
            offset: UInt64(length)
        )
        let commitInfo = Files.CommitInfo(
            path: task.filename,
            mode: .overwrite,
            autorename: false,
            clientModified: task.asset.creationDate ?? task.asset.modificationDate
        )
        NSLog("%@", "..uploaded \(length.formatted()) bytes")
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    static func uploadUrl(dropboxClient: DropboxClient, task: BatchUploader.UploadTask, url: URL) async throws -> Files.UploadSessionFinishArg {
        // We need to close the last chunk - we'll track that by fetching
        // the total file size and checking the total uploaded bytes against it.
        let resources = try url.resourceValues(forKeys: [.fileSizeKey])
        let totalFileSize = resources.fileSize!

        // Dropbox has a file size limit on upload chunks, so we'll batch the file off disk
        // in chunks and upload them piece by piece. Magic number here is from the DB docs -
        // chunk size must be a multiple of 4194304.
        let chunkSize = 4_194_304 * 5
        let dataReader = try AsyncDataFetcher(url: url, chunkSize: chunkSize)

        // start upload with first chunk
        let firstChunk = await dataReader.next()!
        let result = try await dropboxClient.files.uploadSessionStart(
            close: firstChunk.count == totalFileSize,
            input: firstChunk
        ).asyncResponse()
        let sessionId = result.sessionId
        var cursorOffset = firstChunk.count

        // ..keep loading and appending as long as there is more data..
        while let nextData = await dataReader.next() {
            NSLog("%@", "..got chunk")
            let cursor = Files.UploadSessionCursor(
                sessionId: sessionId,
                offset: UInt64(cursorOffset)
            )
            try await dropboxClient.files.uploadSessionAppendV2(
                cursor: cursor,
                close: cursorOffset + nextData.count == totalFileSize,
                input: nextData
            ).asyncResponse()
            cursorOffset += nextData.count
        }

        // ..and the finish call will wrap it up.
        let cursor = Files.UploadSessionCursor(
            sessionId: sessionId,
            offset: UInt64(cursorOffset)
        )
        let commitInfo = Files.CommitInfo(
            path: task.filename,
            mode: .overwrite,
            autorename: false,
            clientModified: task.asset.creationDate ?? task.asset.modificationDate
        )
        NSLog("%@", "..uploaded \(totalFileSize.formatted()) bytes")
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    private static func finish(dropboxClient: DropboxClient, entries: [UploadResult]) async throws -> [FinishResult] {
        var finishArgs = [Files.UploadSessionFinishArg]()
        for entry in entries {
            if case let .success(_, arg) = entry {
                finishArgs.append(arg)
            }
        }

        NSLog("%@", "Finishing \(finishArgs.count) uploads")
        let finishResult = try await dropboxClient.files.uploadSessionFinishBatchV2(entries: finishArgs).asyncResponse()
        var mutableFinishResults = Array(finishResult.entries)
        assert(mutableFinishResults.count == finishArgs.count)
        var finishResults = [FinishResult]()
        for entry in entries {
            switch entry {
            case let .success(filename, _):
                let result: Files.UploadSessionFinishBatchResultEntry = mutableFinishResults.removeFirst()
                switch result {
                case let .success(metaData):
                    finishResults.append(.success(metaData))
                case let .failure(error):
                    finishResults.append(.failure(path: filename, message: error.description))
                }

            case .unchanged:
                finishResults.append(.unchanged)
            case let .failure(path, message):
                finishResults.append(.failure(path: path, message: message))
            }
        }
        assert(mutableFinishResults.isEmpty)
        return finishResults
    }

    private static func jobComplete(persistentContainer: NSPersistentContainer, finishResults: [FinishResult]) async throws {
        // Now we've uploaded all the files, we can connect them to the original assets in core data.
        NSLog("%@", "Complete")
        // Really need better error handling
        let context = persistentContainer.newBackgroundContext()
        try await context.perform {
            for result in finishResults {
                if case let .success(metaData) = result {
                    DropboxFile.insertOrUpdate([metaData], syncRun: "", into: context)
                }
            }
            try context.save()
        }
    }
}
