// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation

/// The progress of a single task. Mutating this will update listeners on the progressManager.
@Observable
final class TaskProgress: Identifiable, @unchecked Sendable {

    enum TaskCategory {
        case fetch
        case upload
    }

    let id: UUID
    let name: String
    let category: TaskCategory
    
    /// Int progress towards the goal
    var progress: Int = 0

    /// The largest possible progress
    var total: Int?

    /// If true the task is complete
    var complete: Bool = false

    fileprivate init(
        name: String,
        total: Int?,
        category: TaskCategory
    ) {
        self.id = UUID()
        self.name = name
        self.total = total
        self.category = category
    }

    /// Calling this will remove the task from the manager
    func remove() {
        total = -1
    }

    /// Marks the task as complete
    func setComplete() {
        complete = true
        total = max(progress, total ?? 0)
    }
}

/// ProgressManager dynamically tracks any number of ongoing tasks with individual progress and total values, and completion state. Tasks
/// are maintained in creation order. Tasks are added to the list with "createTask" and can be removed by calling "remove" on the task.
///
/// This design lets the UI show a list of all ongoing operations and for those operations to constantly update themselves and show
/// progress towards the goal without needing a reference back to the UI.
@Observable
@MainActor
final class ProgressManager {
    var states: [TaskProgress] = []
    
    init() {}
    
    func createTask(named name: String, total: Int? = nil, category: TaskProgress.TaskCategory) -> TaskProgress {
        let newState = TaskProgress(name: name, total: total, category: category)
        states.append(newState)
        watchForRemoval(newState)
        return newState
    }
    
    func reset() {
        states = []
    }

    func watchForRemoval(_ progress: TaskProgress) {
        withObservationTracking {
            if let total = progress.total, total < 0 {
                states.removeAll(where: { $0.id == progress.id })
            }
        } onChange: { [weak self] in
            if (progress.total ?? 0) >= 0 {
                Task { @MainActor in
                    self?.watchForRemoval(progress)
                }
            }
        }
    }
}
