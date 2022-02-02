//  Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import KeychainSwift
import Photos
import SwiftyDropbox
import UIKit

struct ServiceState {
    var progress: Int = 0
    var total: Int = 0
    var complete: Bool = false
    var errors: [String] = []
}

protocol SyncManagerDelegate: NSObjectProtocol {
    func syncManagerUpdatedState(_ syncManager: SyncManager)
}

class SyncManager {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"
    private let keychain = KeychainSwift()

    let persistentContainer: NSPersistentContainer

    var syncing: Bool = false
    var errors: [String] = []
    var photoState: ServiceState?
    var dropboxState: ServiceState?
    var uploadState: ServiceState?

    public weak var delegate: SyncManagerDelegate?

    public var isLoggedIn: Bool { return dropboxClient != nil }
    private var dropboxClient: DropboxClient?

    init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
        connect()
    }

    func connect() {
        if let accessToken = keychain.get(Self.KeychainDropboxAccessToken) {
            dropboxClient = DropboxClient(accessToken: accessToken)
        } else {
            dropboxClient = nil
        }
    }

    func logIn(accessToken: String) {
        keychain.set(accessToken, forKey: Self.KeychainDropboxAccessToken)
        connect()
    }

    func logOut() {
        dropboxClient?.auth.tokenRevoke().response { _, _ in
            // We don't care if there are errors
        }
        keychain.delete(Self.KeychainDropboxAccessToken)
        dropboxClient = nil
    }

    func maybeSync() {
        guard !syncing else { return }
        guard isLoggedIn else { return }
        guard PhotoKitManager.hasPermission else { return }
        sync()
    }

    func sync() {
        assert(!syncing)
        guard let client = dropboxClient else {
            fatalError()
        }
        syncing = true

        let photoManager = PhotoKitManager(persistentContainer: persistentContainer) { progress in
            NSLog("photo progress is %@", String(describing: progress))
            self.photoState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }
        let dropboxManager = DropboxManager(persistentContainer: persistentContainer, dropboxClient: client) { progress in
            NSLog("dropbox progress is %@", String(describing: progress))
            self.dropboxState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }
        let uploadManager = UploadManager(persistentContainer: persistentContainer, dropboxClient: client) { progress in
            NSLog("upload progress is %@", String(describing: progress))
            self.uploadState = progress
            self.delegate?.syncManagerUpdatedState(self)
        }

        Task {
            do {
                NSLog("%@", "Starting photo sync")
                async let photoFetch: Void = photoManager.sync()
                NSLog("%@", "Starting dropbox sync")
                async let dropboxFetch: Void = dropboxManager.sync()

                try await photoFetch
                try await dropboxFetch

            } catch let error {
                fatalError(error.localizedDescription)
            }
            do {
                NSLog("%@", "Starting upload")
                try await uploadManager.sync()
                syncing = false
            } catch let error {
                NSLog("%@", "Upload failed - \(error) \(String(describing: error)) \(error.localizedDescription)")
                fatalError(error.localizedDescription)
            }
        }
    }
}
