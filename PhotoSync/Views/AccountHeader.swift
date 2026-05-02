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
