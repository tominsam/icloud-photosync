// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation

/// The progress of a single task. Mutating this will update listeners on the progressManager.
struct TaskProgress: Identifiable, Sendable {

    let name: String
    let id: UUID
    
    /// Int progress towards the goal
    var progress: Int = 0 { didSet {
        notify(self)
        if progress > total {
            total = progress
        }
    }}

    /// The largest possible progress
    var total: Int = 0 { didSet { notify(self) }}

    /// If true the task is complete
    var complete: Bool = false { didSet { notify(self) }}

    private let notify: @Sendable (TaskProgress) -> Void

    fileprivate init(name: String, total: Int, notify: @escaping @Sendable (TaskProgress) -> Void) {
        self.id = UUID()
        self.name = name
        self.total = total
        self.notify = notify
    }

    /// Calling this will remove the task from the manager
    mutating func remove() {
        total = -1
    }

    /// Marks the task as complete
    mutating func setComplete() {
        complete = true
    }
}

/// ProgressManager dynamically tracks any number of ongoing tasks with individual progress and total values, and completion state. Tasks
/// are maintained in creation order. Tasks are added to the list with "createTask" and can be removed by calling "remove" on the task.
///
/// This design lets the UI show a list of all ongoing operations and for those operations to constantly update themselves and show
/// progress towards the goal without needing a reference back to the UI.
actor ProgressManager {
    let notify: @MainActor ([TaskProgress]) -> Void
    var states: [TaskProgress] = []

    init(notify: @escaping @MainActor ([TaskProgress]) -> Void) {
        self.notify = notify
    }

    nonisolated func createTask(named name: String, total: Int = 0) -> TaskProgress {
        let newState = TaskProgress(name: name, total: total, notify: { [weak self] state in
            Task { await self?.updateTask(state) }
        })
        Task { await self.updateTask(newState) }
        return newState
    }
    
    private func updateTask(_ state: TaskProgress) {
        if state.total < 0 {
            // state is finished
            states.removeAll { $0.id == state.id }
        } else if let index = states.firstIndex(where: { $0.id == state.id }) {
            // update existing state
            states[index] = state
        } else {
            // new state
            states.append(state)
        }
        let states = self.states
        DispatchQueue.main.async {
            self.notify(states)
        }
    }

}
