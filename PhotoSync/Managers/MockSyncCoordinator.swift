// Copyright 2022 Thomas Insam. All rights reserved.

import Foundation

@MainActor
@Observable
class MockSyncCoordinator: SyncCoordinator {
    var pendingPlan: UploadManager.SyncPlan? = nil
    var isLoggedIn: Bool = false
    var dropboxEmail: String? = nil
    var errors: [ServiceError] = []
    var states: [TaskProgress] = []

    func connectDropbox() {}
    func disconnectDropbox() { isLoggedIn = false; dropboxEmail = nil }
    func confirmPlan() { pendingPlan = nil }
}
