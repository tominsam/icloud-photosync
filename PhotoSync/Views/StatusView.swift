import SwiftUI

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

                if let plan = syncCoordinator.pendingPlan, !plan.isEmpty {
                    PlanButtons(
                        confirm: { Task { await syncCoordinator.confirmPlan() } },
                        fetchOnly: plan.unknown.isEmpty ? nil : { Task { await syncCoordinator.confirmPlanFetchOnly() } }
                    )
                } else if !uploadStates.isEmpty && uploadStates.allSatisfy({ $0.total == 0 || $0.complete }) {
                    VStack(spacing: 12) {
                        Text("Nothing to do!")
                            .font(.title2)
                            .bold()
                        Text("Your photos are backed up.")
                            .foregroundStyle(.secondary)
                        Button(action: {
                            Task { await syncCoordinator.sync() }
                        }, label: {
                            Text("Sync again")
                        })
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .padding(.bottom, 300) // for scroll convenience
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .top) {
            Color.clear.frame(height: 0)
        }
    }
}

struct ErrorList: View {
    var errors: [ServiceError]

    var body: some View {
        if !errors.isEmpty {
            Text("Errors")
                .headerStyle()
                .padding(.horizontal)

            ForEach(errors, id: \.id) { error in
                Text(error.message)
                    .padding(.horizontal)
            }
        }
    }
}

extension View {
    func headerStyle() -> some View {
        self
            .font(.headline)
            .kerning(2)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

#Preview("All done") {
    let coordinator = MockSyncCoordinator()
    coordinator.isLoggedIn = true
    coordinator.dropboxEmail = "alice@example.com"
    coordinator.states = [
        mockTask(named: "Local photos", progress: 1000, total: 1000, category: .fetch),
        mockTask(named: "Dropbox", progress: 1000, total: 1000, category: .fetch),
        mockTask(progress: 0, total: 0),
        mockTask(progress: 0, total: 0),
        mockTask(progress: 0, total: 0),
    ]
    return StatusView(syncCoordinator: coordinator)
}

#Preview {
    let coordinator = MockSyncCoordinator()
    coordinator.isLoggedIn = true
    coordinator.dropboxEmail = "alice@example.com"
    coordinator.states = [
        mockTask(progress: 10, category: .fetch),
        mockTask(progress: 1, category: .fetch),
        mockTask(progress: 10),
        mockTask(progress: 10),
        mockTask(progress: 3),
        mockTask(progress: 5, withAssets: true),
    ]
    coordinator.errors = [
        ServiceError(path: "/", message: "message", error: nil),
        ServiceError(path: "/", message: "message", error: nil),
        ServiceError(path: "/", message: "message", error: nil),
    ]
    coordinator.pendingPlan = mockPlan()
    return StatusView(syncCoordinator: coordinator)
}
