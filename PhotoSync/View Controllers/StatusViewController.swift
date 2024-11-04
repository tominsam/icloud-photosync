//
//  StatusViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import SwiftUI

struct StateLabel: View {
    let leading: String
    let state: ServiceState

    var body: some View {
        ZStack {
            // background is a progress bar that fills up behind the label
            GeometryReader { metrics in
                if let progress = state.progressPercent {
                    Color.green
                        .opacity(state.complete ? 0.1 : 0.3)
                        .frame(width: metrics.size.width * progress)
                }
            }

            HStack {
                Text(leading).fixedSize(horizontal: true, vertical: true)
                Spacer()
                Text(state.stringState)
            }
            // Pad the label, not the background
            .padding([.leading, .trailing])
            .padding([.top, .bottom], 12)
        }
    }

}

struct StatusView: View {

    @ObservedObject
    var syncManager: SyncManager

    @ViewBuilder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {

                Text("Sync")
                    .font(.title)
                    .padding()

                ForEach(syncManager.states, content: { state in
                    StateLabel(leading: state.name, state: state)
                })

                Divider()
                    .padding([.leading, .trailing])

                Text("Errors")
                    .font(.title)
                    .padding()

                ForEach(syncManager.errors, id: \.id, content: { error in
                    Text(error.message)
                })

            }
        }

        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if syncManager.isLoggedIn {
                    Button("Log out") {
                        // TODO
                    }
                } else {
                    Button("Connect to Dropbox") {
                        syncManager.connectToDropbox()
                    }
                }
            }
        }
    }
}

class StatusViewController: UIHostingController<StatusView> {

    var syncManager: SyncManager

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
        super.init(rootView: StatusView(syncManager: syncManager))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension ServiceState {
    var stringState: String {
        if complete {
            return "Complete (\(total))"
        } else {
            return "\(progress) / \(total)"
        }
    }

    var progressPercent: Double? {
        if complete {
            return 1
        }
        if total == 0 {
            return nil
        }
        return Double(progress) / Double(total)
    }
}

//    func updateDropboxNavigationItem() {
//        let item: UIBarButtonItem
//        if syncManager.isLoggedIn {
//            item = UIBarButtonItem(primaryAction: UIAction(title: "Log out", handler: { _ in
//                DropboxClientsManager.resetClients()
//                self.updateDropboxNavigationItem()
//                self.startDropboxSync()
//            }))
//        } else {
//            item = UIBarButtonItem(primaryAction: UIAction(title: "Connect to Dropbox", handler: { _ in
//                let scopeRequest = ScopeRequest(
//                    scopeType: .user,
//                    scopes: ["files.metadata.read", "files.content.write"],
//                    includeGrantedScopes: false)
//                DropboxClientsManager.authorizeFromControllerV2(
//                    UIApplication.shared,
//                    controller: self.navigationController,
//                    loadingStatusDelegate: nil,
//                    openURL: { UIApplication.shared.open($0, options: [:], completionHandler: nil) },
//                    scopeRequest: scopeRequest)
//            }))
//        }
//
//        navigationController.viewControllers.first?.navigationItem.rightBarButtonItem = item
//    }
