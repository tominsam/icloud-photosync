//  Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import KeychainSwift
import Photos
import OrderedCollections
import SwiftyDropbox
import UIKit

struct ServiceError: Identifiable {
    let id = UUID()
    let path: String
    let message: String
    let error: Error?
}

struct ServiceState {
    var progress: Int = 0
    var total: Int = 0
    var complete: Bool = false
}

class SyncManager: ObservableObject {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"
    private let keychain = KeychainSwift()

    static let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PhotoSync", conformingTo: .folder)

    let persistentContainer: NSPersistentContainer

    @Published
    var isLoggedIn: Bool = false
    @Published
    var state: OrderedDictionary<String, ServiceState> = .init()
    @Published
    var errors: [ServiceError] = []

    private var dropboxClient: DropboxClient? { DropboxClientsManager.authorizedClient }

    init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
    }

    var syncTask: Task<Void, Never>?

    func maybeSync() {
        isLoggedIn = dropboxClient != nil
        guard isLoggedIn else { return }
        guard PhotoKitManager.hasPermission else { return }
        guard syncTask == nil else { return }
        syncTask = Task {
            defer { syncTask = nil }
            await sync()
        }
    }

    @MainActor
    func sync() async {
        guard let client = dropboxClient else {
            fatalError()
        }

        // Clear out anything we left in temp from the last run
        try? FileManager.default.createDirectory(at: SyncManager.tempDir, withIntermediateDirectories: true)
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: SyncManager.tempDir, includingPropertiesForKeys: nil) {
            for file in tempFiles {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    NSLog("%@", "Failed to delete temp file! \(error)")
                }
            }
        }

        let progressUpdate: (String, ServiceState) -> Void = { [weak self] name, progress in
            DispatchQueue.main.async {
                if progress.total < 0 {
                    self?.state[name] = nil
                } else {
                    self?.state[name] = progress
                }
            }
        }

        let photoManager = PhotoKitManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            progressUpdate: progressUpdate,
            errorUpdate: { [weak self] error in
                self?.errors.append(error)
            })
        let dropboxManager = DropboxManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            progressUpdate: progressUpdate,
            errorUpdate: { [weak self] error in
                self?.errors.append(error)
            })
        let uploadManager = UploadManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            progressUpdate: progressUpdate,
            errorUpdate: { [weak self] error in
                self?.errors.append(error)
            })

        do {
            NSLog("%@", "Starting photo sync")
            async let photoFetch: Void = photoManager.sync()
            NSLog("%@", "Starting dropbox sync")
            async let dropboxFetch: Void = dropboxManager.sync()

            try await photoFetch
            try await dropboxFetch
        } catch {
            fatalError(error.localizedDescription)
        }
        if !errors.isEmpty {
            NSLog("There are errors in initial sync!")
            return
        }

        do {
            NSLog("%@", "Starting upload")
            try await uploadManager.sync(allAssets: photoManager.allAssets)
        } catch {
            NSLog("%@", "Upload failed - \(error) \(String(describing: error)) \(error.localizedDescription)")
            fatalError(error.localizedDescription)
        }

        // resync dropbox at the end
        try? await dropboxManager.sync()
    }
}
