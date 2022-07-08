//  Copyright 2020 Thomas Insam. All rights reserved.

import CoreData
import CryptoKit
import Foundation
import Photos
import SwiftyDropbox

class Manager {
    let persistentContainer: NSPersistentContainer
    let dropboxClient: DropboxClient

    private let progressUpdate: @MainActor(ServiceState) -> Void
    private var _state: ServiceState?

    @MainActor
    func setTotal(_ total: Int) async {
        var state = self._state ?? ServiceState(progress: 0, total: 0)
        state.total = total
        state.complete = false
        self._state = state
        let updateState = state
        progressUpdate(updateState)
    }

    @MainActor
    func setProgress(_ progress: Int) async {
        var state = self._state ?? ServiceState(progress: 0, total: 0)
        state.progress = progress
        state.complete = false
        self._state = state
        let updateState = state
        progressUpdate(updateState)
    }

    @MainActor
    func addProgress(_ progress: Int) async {
        var state = self._state ?? ServiceState(progress: 0, total: 0)
        state.progress += progress
        state.complete = false
        self._state = state
        let updateState = state
        progressUpdate(updateState)
    }

    @MainActor
    func markComplete() async {
        var state = self._state ?? ServiceState(progress: 0, total: 0)
        state.complete = true
        self._state = state
        let updateState = state
        progressUpdate(updateState)
    }

    @MainActor
    func recordError(_ error: ServiceError) async {
        NSLog("Recording error: %@ : %@", error.path, error.message)
        var state = _state ?? ServiceState(progress: 0, total: 0)
        state.errors.append(error)
        self._state = state
        progressUpdate(state)
    }

    init(persistentContainer: NSPersistentContainer, dropboxClient: DropboxClient, progressUpdate: @MainActor @escaping (ServiceState) -> Void) {
        self.persistentContainer = persistentContainer
        self.dropboxClient = dropboxClient
        self.progressUpdate = progressUpdate
    }

}
