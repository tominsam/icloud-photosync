import SwiftUI

struct AccountHeader: View {
    var syncCoordinator: SyncCoordinator

    var body: some View {
        HStack {
            if syncCoordinator.isLoggedIn {
                Text(syncCoordinator.dropboxEmail ?? "Dropbox").bold()
                Spacer()
                Button("Log out") {
                    syncCoordinator.disconnectDropbox()
                }
            } else {
                Text("Not connected").bold()
                Spacer()
                Button("Connect to Dropbox") {
                    syncCoordinator.connectDropbox()
                }
            }
        }
        .padding([.leading, .trailing])
        .padding([.top, .bottom], 12)
    }
}

struct ErrorList: View {
    var errors: [ServiceError]

    var body: some View {
        Text("Errors")
            .font(.title)
            .padding()

        ForEach(errors, id: \.id) { error in
            Text(error.message)
                .padding(.horizontal)
        }
    }
}

struct PlanButtons: View {
    var confirm: () -> Void

    var body: some View {
        Button("Proceed", action: confirm)
            .buttonStyle(.borderedProminent)
            .padding()
    }
}

struct SectionView: View {
    var title: String
    var states: [TaskProgress]

    var body: some View {
        Text(title)
            .font(.title)
            .padding([.leading, .top])

        if !states.isEmpty {
            ForEach(states) { state in
                StateLabel(leading: state.name, state: state)
            }
        } else {
            StateLabel(leading: "Waiting", state: nil)
        }
    }
}

struct StatusView: View {

    var syncCoordinator: SyncCoordinator

    var fetchStates: [TaskProgress] { syncCoordinator.states.filter { $0.category == .fetch } }
    var uploadStates: [TaskProgress] { syncCoordinator.states.filter { $0.category == .upload } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                AccountHeader(syncCoordinator: syncCoordinator)
                SectionView(title: "Fetch", states: fetchStates)
                SectionView(title: "Upload", states: uploadStates)
                ErrorList(errors: syncCoordinator.errors)
                if syncCoordinator.pendingPlan != nil {
                    PlanButtons(confirm: syncCoordinator.confirmPlan)
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    let manager = ProgressManager()
    let coordinator = MockSyncCoordinator()
    coordinator.isLoggedIn = true
    coordinator.dropboxEmail = "alice@example.com"
    let task = manager.createTask(named: "Foo", total: 10, category: .fetch)
    task.progress = 5
    coordinator.states = [
        task,
        manager.createTask(named: "Bar", total: 10, category: .fetch),
        manager.createTask(named: "Baz", total: 10, category: .upload),
        manager.createTask(named: "Ning", total: 10, category: .upload),
    ]
    coordinator.errors = [
        ServiceError(path: "/", message: "message", error: nil),
        ServiceError(path: "/", message: "message", error: nil),
        ServiceError(path: "/", message: "message", error: nil),
        ServiceError(path: "/", message: "message", error: nil),
    ]
    coordinator.pendingPlan = .init(
        uploads: [],
        replacements: [],
        unknown: [],
        deletions: [],
        uploadState: manager.createTask(named: "Upload", category: .upload),
        replacementState: manager.createTask(named: "Replace", category: .upload),
        unknownState: manager.createTask(named: "Unknown", category: .upload),
        deletionState: manager.createTask(named: "Delete", category: .upload),
    )
    return StatusView(syncCoordinator: coordinator)
}
