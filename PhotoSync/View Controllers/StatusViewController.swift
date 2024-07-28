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
                        .opacity(0.3)
                        .frame(width: metrics.size.width * progress)
                }
            }

            HStack {
                Text(leading).fixedSize(horizontal: true, vertical: true)
                Spacer()
                Text(state.stringState)
            }
            // Pad the label, not the background
            .padding()
        }
    }

}

struct StatusView: View {

    @ObservedObject
    var syncManager: SyncManager

    var body: some View {
        VStack {
            VStack(alignment: .leading) {

                Text("Sync")
                    .font(.title)
                    .padding()

                StateLabel(leading: "Photos database", state: syncManager.photoState)
                StateLabel(leading: "Dropbox", state: syncManager.dropboxState)
                StateLabel(leading: "Upload", state: syncManager.uploadState)

                Divider()
                    .padding([.leading, .trailing])

                Text("Errors")
                    .font(.title)
                    .padding()

            }
            // Seems to be required so that the table has all the flex
            .fixedSize(horizontal: false, vertical: true)

            Table(syncManager.errors) {
                TableColumn("Path", value: \.path)
                TableColumn("Messasge", value: \.message)
            }.frame(maxHeight: .infinity)
        }

        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if syncManager.isLoggedIn {
                    Button("Log out") {
                        // TODO
                    }
                } else {
                    Button("Connect to Dropbox") {
                        // TODO
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
            if errors.isEmpty {
                return "Complete (\(total))"
            } else {
                return "Failed (\(errors.count) errors)"
            }
        } else if total == 0 {
            return "Waiting"
        } else {
            return "Fetching \(progress) / \(total)"
        }
    }

    var progressPercent: Double? {
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
