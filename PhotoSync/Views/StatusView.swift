import SwiftUI

struct StatusView: View {

    var syncCoordinator: SyncCoordinator

    @ViewBuilder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {

                Text("Sync")
                    .font(.title)
                    .padding()

                ForEach(syncCoordinator.states, content: { state in
                    StateLabel(leading: state.name, state: state)
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

                Divider()
                    .padding([.leading, .trailing])

                Text("Errors")
                    .font(.title)
                    .padding()

                ForEach(syncCoordinator.errors, id: \.id, content: { error in
                    Text(error.message)
                })

            }
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
