// Copyright 2022 Thomas Insam. All rights reserved.

import Foundation

#if DEBUG

@MainActor
@Observable
class MockSyncCoordinator: SyncCoordinator {
    var pendingPlan: UploadManager.SyncPlan?
    var isLoggedIn: Bool = false
    var dropboxEmail: String?
    var errors: [ServiceError] = []
    var states: [TaskProgress] = []

    func connectDropbox() {}
    func disconnectDropbox() { isLoggedIn = false; dropboxEmail = nil }
    func sync() {}
    func confirmPlan() { pendingPlan = nil }
    func confirmPlanFetchOnly() { pendingPlan = nil }
}

@MainActor
let mockProgressManager = ProgressManager()

@MainActor
func mockTask(named: String? = nil, progress: Int, total: Int = 10, category: TaskProgress.TaskCategory = .upload, withAssets: Bool = false) -> TaskProgress {
    let name = named ?? "Task \(mockProgressManager.states.count + 1)"
    let task = mockProgressManager.createTask(named: name, total: total, category: category)
    task.progress = progress
    if task.progress >= total {
        task.setComplete()
    }
    if withAssets {
        task.assets = (0..<10).map { MockAsset(localIdentifier: "preview-\($0)") }
    }
    return task
}

@MainActor
func mockPlan() -> UploadManager.SyncPlan {
    UploadManager.SyncPlan(
        uploads: [],
        replacements: [],
        unknown: [],
        deletions: [],
        uploadState: mockTask(progress: 0),
        replacementState: mockTask(progress: 0),
        unknownState: mockTask(progress: 0),
        deletionState: mockTask(progress: 0),
    )
}

#endif
