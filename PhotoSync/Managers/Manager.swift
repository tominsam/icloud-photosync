//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox

class Manager {
    let persistentContainer: NSPersistentContainer
    let dropboxClient: DropboxClient

    let progressUpdate: (String, ServiceState) -> Void
    private let errorUpdate: (ServiceError) -> Void

    @MainActor
    func setProgress(_ progress: Int, total: Int, named name: String) async {
        progressUpdate(name, ServiceState(progress: progress, total: total))
    }

    @MainActor
    func markComplete(_ total: Int, named name: String) async {
        progressUpdate(name, ServiceState(progress: total, total: total, complete: true))
    }

    @MainActor
    func recordError(_ error: ServiceError) async {
        NSLog("Recording error: %@ : %@", error.path, error.message)
        errorUpdate(error)
    }

    init(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, progressUpdate: @escaping (String, ServiceState) -> Void, errorUpdate: @escaping (ServiceError) -> Void) {
        self.persistentContainer = persistentContainer
        self.dropboxClient = dropboxClient
        self.progressUpdate = progressUpdate
        self.errorUpdate = errorUpdate
    }

}
