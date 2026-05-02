// Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import Photos
import SwiftyDropbox
import UIKit

// Upload bundles of assets to dropbox at once - this is much much faster than uploading individually,
// even though it's much more complicated, because Dropbox has internal transaction / locking that effectively
// prevent me uploading more than one file at once.
@MainActor
class UploadOperation {
    enum UploadState {
        // File is not in dropbox
        case new
        // File is in dropbox, local hash is diffrent
        case replacement
        // File is in dropbox, local hash is nil
        case unknown
    }
    struct UploadTask {
        let asset: PHAssetProtocol
        let filename: String
        let existingContentHash: String?
        let assetContentHash: String?
        let state: UploadState
    }

    private enum UploadResult {
        case success(String, Files.UploadSessionFinishArg)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    enum FinishResult {
        case success(Files.FileMetadata)
        case unchanged
        case failure(path: String, message: String, error: Error?)
    }

    /// Downloads a chunk of assets from PhotoKit, saves their hashes, and returns only the
    /// items that actually need uploading (i.e. whose hash differs from the existing remote hash).
    static func fetchBatch(
        database: Database,
        tasks: [UploadTask],
        progressManager: ProgressManager
    ) async -> [(UploadTask, AssetData)] {
        let fetchState = progressManager.createTask(named: "Fetching", total: tasks.count, category: .upload)
        fetchState.assets = tasks.map(\.asset)
        defer { fetchState.remove() }

        return await tasks.asyncMap { task -> (UploadTask, AssetData)? in
            let data = await download(database: database, asset: task.asset)
            fetchState.progress += 1
            if data.hash != nil && task.existingContentHash == data.hash {
                // Already uploaded — hash matches, nothing to do.
                return nil
            }
            return (task, data)
        }.compactMap(\.self)
    }

    /// Uploads a batch of pre-fetched items to Dropbox.
    static func uploadBatch(
        dropboxClient: DropboxClient,
        items: [(UploadTask, AssetData)],
        progressManager: ProgressManager
    ) async -> [FinishResult] {
        guard !items.isEmpty else { return [] }

        let totalBytes = items.reduce(0) { $0 + $1.1.byteSize }
        let uploadState = progressManager.createTask(named: "Uploading", total: totalBytes, category: .upload)
        uploadState.unit = .bytes
        uploadState.assets = items.map(\.0.asset)
        defer { uploadState.remove() }

        var uploadResults = [UploadResult]()
        for (task, assetData) in items {
            do {
                let uploadSession: Files.UploadSessionFinishArg
                switch assetData {
                case let .data(data, hash):
                    uploadSession = try await uploadData(
                        dropboxClient: dropboxClient,
                        filename: task.filename,
                        date: task.asset.creationDate ?? task.asset.modificationDate,
                        contentHash: hash,
                        data: data)
                    assert(uploadSession.contentHash! == data.dropboxContentHash())
                case .url(let url, let hash), .tempUrl(let url, let hash):
                    uploadSession = try await uploadUrl(
                        dropboxClient: dropboxClient,
                        filename: task.filename,
                        date: task.asset.creationDate ?? task.asset.modificationDate,
                        contentHash: hash,
                        url: url)
                    assert(uploadSession.contentHash == url.dropboxContentHash())
                case .failure(let error):
                    throw error
                }
                if case .tempUrl(let url, _) = assetData {
                    // We exported a video to a temp file, let's clean that up
                    try? FileManager.default.removeItem(at: url)
                }
                uploadState.progress += assetData.byteSize
                uploadResults.append(.success(task.filename, uploadSession))
            } catch {
                uploadState.progress += assetData.byteSize
                uploadResults.append(.failure(path: task.filename, message: error.localizedDescription, error: error))
            }
        }

        guard !uploadResults.isEmpty else { return [] }

        do {
            // Batched dropbox uploads work by uploading several files, then a "finish" call
            // adds them all to the dropbox. We have to work like this or it's trivially easy
            // to hit the upload rate limit.
            return try await finish(dropboxClient: dropboxClient, entries: uploadResults)
        } catch {
            return uploadResults.map { result -> FinishResult in
                switch result {
                case .success(let filename, _):
                    return .failure(path: filename, message: error.localizedDescription, error: error)
                case .unchanged:
                    return .unchanged
                case let .failure(path, message, error):
                    return .failure(path: path, message: message, error: error)
                }
            }
        }
    }

    static func download(database: Database, asset: PHAssetProtocol) async -> AssetData {
        // Get photo from photoKit. This is slow.
        do {
            // this is the _final_ image data, including patched exif for edited files and videos.
            let data = try await asset.getImageData(version: .original)

            // Store the content hash on the database object before we start the upload
            try await database.perform { context in
                if let photo = try Photo.forLocalIdentifier(asset.localIdentifier, in: context) {
                    photo.contentHash = data.hash
                    try context.save()
                } else {
                    fatalError()
                }
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
        return Files.UploadSessionFinishArg(cursor: cursor, commit: commitInfo, contentHash: contentHash)
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

func loggingDuration<R>(_ name: String, _ body: () async throws -> R) async rethrows -> R {
    let startPoint = Date()
    defer { NSLog("\(name): \(Date().timeIntervalSince(startPoint)) seconds") }
    return try await body()
}

func loggingDuration<R>(_ name: String, _ body: () throws -> R) rethrows -> R {
    let startPoint = Date()
    defer { NSLog("\(name): \(Date().timeIntervalSince(startPoint)) seconds") }
    return try body()
}
