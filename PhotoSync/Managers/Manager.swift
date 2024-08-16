//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox

class Manager {
    let persistentContainer: NSPersistentContainer
    let dropboxClient: DropboxClient

    let stateManager: StateManager
    private let errorUpdate: (ServiceError) -> Void

    @MainActor
    func recordError(_ error: ServiceError) async {
        NSLog("Recording error: %@ : %@", error.path, error.message)
        errorUpdate(error)
    }

    init(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, stateManager: StateManager, errorUpdate: @escaping (ServiceError) -> Void) {
        self.persistentContainer = persistentContainer
        self.dropboxClient = dropboxClient
        self.stateManager = stateManager
        self.errorUpdate = errorUpdate
    }

}
