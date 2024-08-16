//  Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Combine
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

@MainActor
struct ServiceState: Identifiable {

    let notify: (ServiceState) -> Void

    let name: String
    let id: UUID
    public private(set) var progress: Int = 0 { didSet { notify(self) }}
    public private(set) var total: Int = 0 { didSet { notify(self) }}
    public private(set) var complete: Bool = false { didSet { notify(self) }}

    init(name: String, total: Int, notify: @escaping (ServiceState) -> Void) {
        self.id = UUID()
        self.name = name
        self.total = total
        self.notify = notify
    }

    mutating func remove() {
        total = -1
    }

    mutating func increment(_ by: Int = 1) {
        progress += by
    }

    mutating func setComplete() {
        complete = true
    }

    mutating func updateTotal(to total: Int) {
        self.total = total
    }
}

@MainActor
class StateManager {
    let notify: ([ServiceState]) -> Void
    var states: [ServiceState] = []

    init(notify: @escaping ([ServiceState]) -> Void) {
        self.notify = notify
    }

    func createState(named name: String, total: Int = 0) -> ServiceState {
        let newState = ServiceState(name: name, total: total, notify: { [weak self] state in
            guard let self else { return }
            if state.total < 0 {
                states.removeAll { $0.id == state.id }
            } else {
                if let index = states.firstIndex(where: { $0.id == state.id }) {
                    states[index] = state
                } else {
                    states.append(state)
                }
            }
            notify(states)
        })
        states.append(newState)
        notify(states)
        return newState
    }

}

@MainActor
class SyncManager: ObservableObject {
    static let KeychainDropboxAccessToken = "KeychainDropboxAccessToken"
    private let keychain = KeychainSwift()

    static let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PhotoSync", conformingTo: .folder)

    let persistentContainer: NSPersistentContainer

    @Published
    var isLoggedIn: Bool = false
    @Published
    var states: [ServiceState] = []
    @Published
    var errors: [ServiceError] = []

    lazy var stateManager = StateManager(notify: { [weak self] newStates in
        self?.states = newStates
    })

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

        let photoManager = PhotoKitManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            stateManager: stateManager,
            errorUpdate: { [weak self] error in
                self?.errors.append(error)
            })
        let dropboxManager = DropboxManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            stateManager: stateManager,
            errorUpdate: { [weak self] error in
                self?.errors.append(error)
            })
        let uploadManager = UploadManager(
            persistentContainer: persistentContainer,
            dropboxClient: client,
            stateManager: stateManager,
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
