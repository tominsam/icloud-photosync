//  Copyright 2020 Thomas Insam. All rights reserved.

import CollectionConcurrencyKit
import CoreData
import Photos
import SwiftyDropbox
import UIKit
import AsyncAlgorithms

enum UploadError: Error {
    case photoKit(String)
    case dropbox(String)
}

// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
class BatchUploader: LoggingOperation {
    public struct UploadTask {
        let asset: PHAsset
        let filename: String
        let existingContentHash: String?
        let isNewFile: Bool
    }

    private enum UploadResult {
        case success(String, Files.UploadSessionFinishArg)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    public enum FinishResult {
        case success(Files.FileMetadata)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    public static func batchUpload(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, tasks: [UploadTask]) async -> [FinishResult] {
        NSLog("%@", "Downloading chunk of \(tasks.count) files")

        // Download all the images, one at a time, in advance.
        let data = await tasks.asyncMap { await download(persistentContainer: persistentContainer, asset: $0.asset) }

        NSLog("%@", "Uploading chunk of \(data.filter { $0.hash != nil }.count) files")

        // concurrently upload all the files
        let uploadResults = await withTaskGroup(of: UploadResult.self) { group -> [UploadResult] in
            for (task, data) in zip(tasks, data) {
                group.addTask {
                    let uploadSession: Files.UploadSessionFinishArg?
                    do {
                        switch data {
                        case let .data(data, hash):
                            uploadSession = try await uploadData(
                                dropboxClient: dropboxClient,
                                filename: task.filename,
                                date: task.asset.creationDate ?? task.asset.modificationDate,
                                contentHash: hash,
                                data: data)
                        case let .url(url, hash):
                            uploadSession = try await uploadUrl(
                                dropboxClient: dropboxClient,
                                filename: task.filename,
                                date: task.asset.creationDate ?? task.asset.modificationDate,
                                contentHash: hash,
                                url: url)
                        case .failure(let error):
                            throw error
                        }
                    } catch let error as SwiftyDropbox.CallError<SwiftyDropbox.Files.UploadSessionStartError> {
                        return .failure(path: task.filename, message: error.description, error: error)
                    } catch {
                        return .failure(path: task.filename, message: error.localizedDescription, error: error)
                    }
                    if let uploadSession {
                        return .success(task.filename, uploadSession)
                    } else {
                        return .unchanged
                    }
                }
            }
            var output = [UploadResult]()
            for await value in group {
                output.append(value)
            }
            return output
        }
        do {
            return try await finish(dropboxClient: dropboxClient, entries: uploadResults)
        } catch {
            return [.failure(path: "", message: error.localizedDescription, error: error)]
        }
    }

    private static func download(persistentContainer: NSPersistentContainer, asset: PHAsset) async -> AssetData {
        // Get photo from photoKit. This is slow.
        do {
            let data = try await asset.getImageData()

            // Store the content hash on the database object before we start the upload
            let context = persistentContainer.newBackgroundContext()
            if let photo = try await Photo.forAsset(asset, in: context) {
                // if the photo modified date changed, we should have niled this. If it's set,
                // but different, that's a profound problem with the sync engine and I need to know
                assert(photo.contentHash == nil || photo.contentHash == data.hash)
                photo.contentHash = data.hash
                try await context.performSave()
            }

            return data
        } catch {
            return .failure(error)
        }
    }

    private static func uploadData(dropboxClient: DropboxClient, filename: String, date: Date?, contentHash: String, data: Data) async throws -> Files.UploadSessionFinishArg {
        // Theoretically if data is >150mb we have a problem here, but that seems unlikely
        // for most use cases right now. (hahahaha yes I know)
        let length = data.count
        let result = try await dropboxClient.files.uploadSessionStart(
            close: true,
            contentHash: contentHash,
            input: data
        ).asyncResponse()
        let cursor = Files.UploadSessionCursor(
            sessionId: result.sessionId,
            offset: UInt64(length)
        )
        let commitInfo = Files.CommitInfo(
            path: filename,
            mode: .overwrite,
            autorename: false,
            clientModified: date
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo)
    }

    private static func uploadUrl(dropboxClient: DropboxClient, filename: String, date: Date?, contentHash: String, url: URL) async throws -> Files.UploadSessionFinishArg {
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
            contentHash: firstChunk.dropboxContentHash(),
            input: firstChunk
        ).asyncResponse()
        let sessionId = result.sessionId
        var cursorOffset = firstChunk.count

        // ..keep loading and appending as long as there is more data..
        while let nextData = await dataReader.next() {
            let cursor = Files.UploadSessionCursor(
                sessionId: sessionId,
                offset: UInt64(cursorOffset)
            )
            try await dropboxClient.files.uploadSessionAppendV2(
                cursor: cursor,
                close: cursorOffset + nextData.count == totalFileSize,
                contentHash: nextData.dropboxContentHash(),
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
            path: filename,
            mode: .overwrite,
            autorename: false,
            clientModified: date
        )
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo, contentHash: contentHash)
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
                    finishResults.append(.failure(path: filename, message: error.description, error: nil))
                }

            case .unchanged:
                finishResults.append(.unchanged)
            case let .failure(path, message, error):
                finishResults.append(.failure(path: path, message: message, error: error))
            }
        }
        assert(mutableFinishResults.isEmpty)
        return finishResults
    }

}
