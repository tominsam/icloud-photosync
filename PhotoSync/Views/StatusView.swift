import SwiftUI

struct StatusView: View {

    var syncCoordinator: SyncCoordinator

    var fetchStates: [TaskProgress] { syncCoordinator.states.filter { $0.category == .fetch } }
    var uploadStates: [TaskProgress] { syncCoordinator.states.filter { $0.category == .upload } }

    @ViewBuilder
    func section(title: String, states: [TaskProgress]) -> some View {
        Text(title)
            .font(.title)
            .padding([.leading, .top])

        if !states.isEmpty {
            ForEach(states) { state in
                StateLabel(leading: state.name, state: state)
            }
        } else {
            StateLabel(leading: "…", state: nil)
        }
    }

    @ViewBuilder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {

                section(title: "Fetch", states: fetchStates)

                section(title: "Upload", states: uploadStates)

                Text("Errors")
                    .font(.title)
                    .padding()

                ForEach(syncCoordinator.errors, id: \.id, content: { error in
                    Text(error.message)
                })

                if syncCoordinator.pendingPlan != nil {
                    HStack {
                        Button("Proceed", action: syncCoordinator.confirmPlan)
                            .buttonStyle(.borderedProminent)
                        Button("Cancel", role: .cancel, action: syncCoordinator.cancelPlan)
                            .buttonStyle(.bordered)
                    }
                    .padding()
                }

            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }

        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if syncCoordinator.isLoggedIn {
                    Button("Log out") {
                        syncCoordinator.disconnectDropbox()
                    }
                } else {
                    Button("Connect to Dropbox") {
                        syncCoordinator.connectDropbox()
                    }
                }
            }
        }
    }
}

#Preview {
    StatusView(syncCoordinator: SyncCoordinator(database: Database()))
}
